#!/usr/bin/env bash
# Build the CIX GPU DKMS source package with the project sbuild environment.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=framework.sh
source "${SCRIPT_DIR}/framework.sh"

action="build"
distribution="${CIX_BUILD_DISTRIBUTION:-trixie}"
jobs="${CIX_BUILD_JOBS:-$(cix_default_jobs)}"
nexus_site="${CIX_NEXUS_SITE:-zj}"
output_dir="${CIX_OUTPUT_DIR:-${CIX_WORKSPACE_ROOT}/output}/gpu-dkms"

usage() {
    cat <<'EOF'
Usage: build-gpu-dkms.sh [OPTIONS] [build|clean]

Assemble the GPU source and external Debian metadata, create a source package,
and build it with the native ARM64 sbuild environment.

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

readonly gpu_source="${CIX_WORKSPACE_ROOT}/sources/gpu-kernel"
readonly packaging_dir="${CIX_WORKSPACE_ROOT}/debian/gpu-dkms"
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

[[ -f "${gpu_source}/dkms.conf" ]] || cix_die "GPU source is missing: ${gpu_source}"
[[ -f "${packaging_dir}/control" ]] || cix_die "GPU Debian metadata is missing: ${packaging_dir}"
[[ -f "${sbuild_config}" ]] || cix_die "sbuild configuration is missing: ${sbuild_config}"

if [[ "${action}" == "clean" ]]; then
    if [[ -d "${artifacts_dir}" ]]; then
        cix_log "Remove GPU DKMS package artifacts from ${artifacts_dir}"
        find "${artifacts_dir}" -mindepth 1 -maxdepth 1 -type f \
            \( -name 'cix-gpu-kmd_*' -o -name 'cix-gpu-dkms_*' \) -delete
    fi
    exit 0
fi

cix_require_command dpkg-parsechangelog dpkg-source git rsync sbuild tar
[[ -s "${sbuild_chroot}" ]] ||
    cix_die "sbuild chroot tarball is missing; run ${SCRIPT_DIR}/setup-sbuild.sh first: ${sbuild_chroot}"
[[ -d "${ccache_dir}" ]] ||
    cix_die "sbuild ccache directory is missing; run ${SCRIPT_DIR}/setup-sbuild.sh first: ${ccache_dir}"
[[ -d "${tmpdir_root}" ]] ||
    cix_die "sbuild temporary directory is missing; run ${SCRIPT_DIR}/setup-sbuild.sh first: ${tmpdir_root}"

source_package="$(dpkg-parsechangelog -l"${packaging_dir}/changelog" -S Source)"
debian_version="$(dpkg-parsechangelog -l"${packaging_dir}/changelog" -S Version)"
upstream_version="${debian_version#*:}"
upstream_version="${upstream_version%%-*}"
dkms_name="$(sed -n 's/^PACKAGE_NAME="\([^"]*\)"$/\1/p' "${gpu_source}/dkms.conf" | head -n1)"
dkms_version="$(sed -n 's/^PACKAGE_VERSION="\([^"]*\)"$/\1/p' "${gpu_source}/dkms.conf" | head -n1)"

[[ -n "${source_package}" ]] || cix_die "cannot determine Debian source package name"
[[ -n "${dkms_name}" && -n "${dkms_version}" ]] ||
    cix_die "cannot determine PACKAGE_NAME/PACKAGE_VERSION from dkms.conf"
[[ "${source_package}" == "${dkms_name}" ]] ||
    cix_die "Debian source name ${source_package} does not match DKMS name ${dkms_name}"
[[ "${upstream_version}" == "${dkms_version}" ]] ||
    cix_die "Debian upstream version ${upstream_version} does not match DKMS version ${dkms_version}"

mkdir -p -- "${artifacts_dir}"
work_root="$(mktemp -d "${output_dir}/.gpu-dkms.XXXXXXXXXX")"
readonly work_root
source_tree="${work_root}/${source_package}-${upstream_version}"
readonly source_tree

cleanup() {
    if [[ -d "${work_root}" ]]; then
        rm -rf -- "${work_root}"
    fi
}
trap cleanup EXIT

cix_log "Assemble GPU source package in ${work_root}"
mkdir -p -- "${source_tree}"
rsync -a --exclude=.git --exclude=/debian/ "${gpu_source}/" "${source_tree}/"

source_date_epoch="$(git -C "${gpu_source}" log -1 --format=%ct)"
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

cix_log "GPU DKMS package build complete"
find "${artifacts_dir}" -maxdepth 1 -type f -printf '    %p\n' | sort
