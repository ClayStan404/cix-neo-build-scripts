#!/usr/bin/env bash
# Build the proprietary CIX VPU firmware as a standard Debian package.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=framework.sh
source "${SCRIPT_DIR}/framework.sh"

action="build"
distribution="${CIX_BUILD_DISTRIBUTION:-trixie}"
jobs="${CIX_BUILD_JOBS:-$(cix_default_jobs)}"
nexus_site="${CIX_NEXUS_SITE:-zj}"
output_dir="${CIX_OUTPUT_DIR:-${CIX_WORKSPACE_ROOT}/output}/vpu-firmware"

usage() {
    cat <<'EOF'
Usage: build-vpu-firmware.sh [OPTIONS] [build|clean]

Assemble the manifest-managed proprietary CIX VPU firmware and external
Debian metadata, create a source package, and build it with sbuild.

Options:
  --distribution SUITE  sbuild distribution (default: trixie)
  --jobs COUNT           Parallel package build jobs
  --nexus SITE           sh, zj, wuh, szv, ksh, wux, release, or public
  --output-dir PATH      Source and binary package output directory
  -h, --help             Show this help
EOF
}

while (($#)); do
    case "$1" in
        build|clean)
            action="$1"
            shift
            ;;
        --distribution)
            (($# >= 2)) || cix_die "$1 requires a value"
            distribution="$2"
            shift 2
            ;;
        --jobs)
            (($# >= 2)) || cix_die "$1 requires a value"
            jobs="$2"
            shift 2
            ;;
        --nexus)
            (($# >= 2)) || cix_die "$1 requires a value"
            nexus_site="$2"
            shift 2
            ;;
        --output-dir)
            (($# >= 2)) || cix_die "$1 requires a value"
            output_dir="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            cix_die "unknown argument: $1"
            ;;
    esac
done

cix_validate_debian_13_arm64
cix_validate_nexus_site "${nexus_site}"
cix_validate_positive_integer "jobs" "${jobs}"
[[ "${distribution}" =~ ^[a-zA-Z0-9][a-zA-Z0-9.+_-]*$ ]] ||
    cix_die "invalid distribution: ${distribution}"

readonly source_git="${CIX_WORKSPACE_ROOT}/sources/cix-proprietary"
readonly firmware_rel="cix_proprietary-debs/cix-vpu-umd/usr/lib/firmware"
readonly firmware_dir="${source_git}/${firmware_rel}"
readonly packaging_dir="${CIX_WORKSPACE_ROOT}/debian/vpu-firmware"
readonly sbuild_config="${SCRIPT_DIR}/sbuild/config.pl"
artifacts_dir="$(realpath -m -- "${output_dir}/artifacts")"
readonly artifacts_dir
sbuild_chroot="${CIX_SBUILD_CHROOT:-${HOME}/.cache/sbuild/${distribution}-arm64-sbuild.tar.zst}"
sbuild_chroot="$(realpath -m -- "${sbuild_chroot}")"
readonly sbuild_chroot
ccache_dir="${CIX_SBUILD_CCACHE_DIR:-${XDG_CACHE_HOME:-${HOME}/.cache}/cix-neo-sbuild/ccache}"
ccache_dir="$(realpath -m -- "${ccache_dir}")"
readonly ccache_dir
tmpdir_template="${CIX_SBUILD_TMPDIR_TEMPLATE:-/var/tmp/cix-neo-sbuild/tmp.sbuild.XXXXXXXXXX}"
tmpdir_root="$(dirname -- "${tmpdir_template}")"
readonly tmpdir_template tmpdir_root

[[ -f "${packaging_dir}/control" && -f "${packaging_dir}/source/format" ]] ||
    cix_die "VPU firmware Debian metadata is missing: ${packaging_dir}"
[[ "$(<"${packaging_dir}/source/format")" == "3.0 (quilt)" ]] ||
    cix_die "VPU firmware must use source format 3.0 (quilt)"
[[ -f "${sbuild_config}" ]] || cix_die "sbuild configuration is missing: ${sbuild_config}"

if [[ "${action}" == "clean" ]]; then
    if [[ -d "${artifacts_dir}" ]]; then
        cix_log "Remove VPU firmware package artifacts from ${artifacts_dir}"
        find "${artifacts_dir}" -mindepth 1 -maxdepth 1 -type f -delete
    fi
    exit 0
fi

cix_require_command dpkg-parsechangelog dpkg-source find git grep realpath rsync sbuild tar
git -C "${source_git}" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
    cix_die "proprietary source is not a Git worktree: ${source_git}"
[[ -s "${sbuild_chroot}" ]] ||
    cix_die "sbuild chroot tarball is missing; run ${SCRIPT_DIR}/setup-sbuild.sh first: ${sbuild_chroot}"
[[ -d "${ccache_dir}" ]] ||
    cix_die "sbuild ccache directory is missing; run ${SCRIPT_DIR}/setup-sbuild.sh first: ${ccache_dir}"
[[ -d "${tmpdir_root}" ]] ||
    cix_die "sbuild temporary directory is missing; run ${SCRIPT_DIR}/setup-sbuild.sh first: ${tmpdir_root}"

readonly lfs_pointer_header="version https://git-lfs.github.com/spec/v1"
readonly lfs_include="${firmware_rel}/*.fwb"
is_lfs_pointer() {
    grep -qFx -- "${lfs_pointer_header}" "$1"
}

if [[ -f "${firmware_dir}/h264dec.fwb" ]] &&
    is_lfs_pointer "${firmware_dir}/h264dec.fwb"; then
    git -C "${source_git}" lfs version >/dev/null 2>&1 ||
        cix_die "Git LFS is required to materialize the VPU firmware"
    cix_log "Fetch the manifest-pinned VPU firmware Git LFS objects"
    git -C "${source_git}" lfs pull --include="${lfs_include}" --exclude=''
fi

required_firmware=(
    av1dec.fwb
    avs2dec.fwb
    avsdec.fwb
    h264dec.fwb
    h264enc.fwb
    hevcdec.fwb
    hevcenc.fwb
    jpegdec.fwb
    jpegenc.fwb
    mpeg2dec.fwb
    mpeg4dec.fwb
    vc1dec.fwb
    vp8dec.fwb
    vp8enc.fwb
    vp9dec.fwb
    vp9enc.fwb
)
for firmware_name in "${required_firmware[@]}"; do
    firmware_file="${firmware_dir}/${firmware_name}"
    [[ -s "${firmware_file}" ]] || cix_die "VPU firmware is missing: ${firmware_file}"
    ! is_lfs_pointer "${firmware_file}" ||
        cix_die "VPU firmware is still a Git LFS pointer: ${firmware_file}"
done
if [[ -n "$(git -C "${source_git}" status --porcelain)" ]]; then
    cix_die "proprietary source must be clean before packaging: ${source_git}"
fi

source_package="$(dpkg-parsechangelog -l"${packaging_dir}/changelog" -S Source)"
debian_version="$(dpkg-parsechangelog -l"${packaging_dir}/changelog" -S Version)"
upstream_version="${debian_version#*:}"
upstream_version="${upstream_version%%-*}"
[[ -n "${source_package}" && -n "${upstream_version}" ]] ||
    cix_die "cannot determine VPU firmware source package name and version"

mkdir -p -- "${artifacts_dir}"
work_root="$(mktemp -d "${output_dir}/.vpu-firmware.XXXXXXXXXX")"
readonly work_root
source_tree="${work_root}/${source_package}-${upstream_version}"
readonly source_tree

cleanup() {
    if [[ -d "${work_root}" ]]; then
        rm -rf -- "${work_root}"
    fi
}
trap cleanup EXIT

cix_log "Assemble VPU firmware source package in ${work_root}"
mkdir -p -- "${source_tree}/firmware"
rsync -a --include='*.fwb' --exclude='*' "${firmware_dir}/" "${source_tree}/firmware/"
chmod 0644 -- "${source_tree}/firmware/"*.fwb

source_date_epoch="$(git -C "${source_git}" log -1 --format=%ct)"
orig_tar="${work_root}/${source_package}_${upstream_version}.orig.tar.xz"
tar --sort=name \
    --mtime="@${source_date_epoch}" \
    --owner=0 --group=0 --numeric-owner \
    -C "${work_root}" \
    -cJf "${orig_tar}" \
    "${source_package}-${upstream_version}"

mkdir -p -- "${source_tree}/debian"
rsync -a "${packaging_dir}/" "${source_tree}/debian/"
(
    cd "${work_root}"
    dpkg-source -b "$(basename "${source_tree}")"
)

dsc_file="${work_root}/${source_package}_${debian_version}.dsc"
[[ -s "${dsc_file}" ]] || cix_die "dpkg-source did not create ${dsc_file}"

export SOURCE_DATE_EPOCH="${source_date_epoch}"
export CIX_NEXUS_SITE="${nexus_site}"
export CIX_SBUILD_CHROOT="${sbuild_chroot}"
export CIX_SBUILD_DISTRIBUTION="${distribution}"
export CIX_SBUILD_CCACHE_DIR="${ccache_dir}"
export CIX_SBUILD_OUTPUT_DIR="${artifacts_dir}"
export CIX_SBUILD_TMPDIR_TEMPLATE="${tmpdir_template}"
export DEB_BUILD_OPTIONS="parallel=${jobs}${DEB_BUILD_OPTIONS:+ ${DEB_BUILD_OPTIONS}}"
export SBUILD_CONFIG="${sbuild_config}"

cix_log "Build ${dsc_file} with sbuild"
sbuild \
    --chroot-mode=unshare \
    --dist="${distribution}" \
    --arch=arm64 \
    --build-dir="${artifacts_dir}" \
    "${dsc_file}"

cix_log "VPU firmware package build complete"
find "${artifacts_dir}" -maxdepth 1 -type f -printf '    %p\n' | sort
