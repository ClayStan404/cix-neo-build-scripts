#!/usr/bin/env bash
# Shared sbuild implementation for native packages owned by cix-neo-debian.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=framework.sh
source "${SCRIPT_DIR}/framework.sh"

: "${CIX_NATIVE_TARGET:?CIX_NATIVE_TARGET is required}"
: "${CIX_NATIVE_PACKAGING_REL:?CIX_NATIVE_PACKAGING_REL is required}"
: "${CIX_NATIVE_LABEL:?CIX_NATIVE_LABEL is required}"

action="build"
distribution="${CIX_BUILD_DISTRIBUTION:-trixie}"
jobs="${CIX_BUILD_JOBS:-$(cix_default_jobs)}"
nexus_site="${CIX_NEXUS_SITE:-zj}"
output_dir="${CIX_OUTPUT_DIR:-${CIX_WORKSPACE_ROOT}/output}/${CIX_NATIVE_TARGET}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] [build|clean]

Create the ${CIX_NATIVE_LABEL} native source package and build it with the
native ARM64 sbuild environment.

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
[[ "${CIX_NATIVE_TARGET}" =~ ^[a-z0-9][a-z0-9-]*$ ]] ||
    cix_die "invalid native target: ${CIX_NATIVE_TARGET}"

readonly packaging_dir="${CIX_WORKSPACE_ROOT}/${CIX_NATIVE_PACKAGING_REL}"
readonly packaging_git="${CIX_WORKSPACE_ROOT}/debian"
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
    cix_die "${CIX_NATIVE_LABEL} Debian source is missing: ${packaging_dir}"
[[ "$(<"${packaging_dir}/source/format")" == "3.0 (native)" ]] ||
    cix_die "${CIX_NATIVE_LABEL} must use source format 3.0 (native)"
[[ -f "${sbuild_config}" ]] || cix_die "sbuild configuration is missing: ${sbuild_config}"

if [[ "${action}" == "clean" ]]; then
    if [[ -d "${artifacts_dir}" ]]; then
        cix_log "Remove ${CIX_NATIVE_LABEL} package artifacts from ${artifacts_dir}"
        find "${artifacts_dir}" -mindepth 1 -maxdepth 1 -type f -delete
    fi
    exit 0
fi

cix_require_command dpkg-parsechangelog dpkg-source find git realpath rsync sbuild
[[ -s "${sbuild_chroot}" ]] ||
    cix_die "sbuild chroot tarball is missing; run ${SCRIPT_DIR}/setup-sbuild.sh first: ${sbuild_chroot}"
[[ -d "${ccache_dir}" ]] ||
    cix_die "sbuild ccache directory is missing; run ${SCRIPT_DIR}/setup-sbuild.sh first: ${ccache_dir}"
[[ -d "${tmpdir_root}" ]] ||
    cix_die "sbuild temporary directory is missing; run ${SCRIPT_DIR}/setup-sbuild.sh first: ${tmpdir_root}"

source_package="$(dpkg-parsechangelog -l"${packaging_dir}/changelog" -S Source)"
debian_version="$(dpkg-parsechangelog -l"${packaging_dir}/changelog" -S Version)"
tree_version="${debian_version#*:}"
[[ -n "${source_package}" && -n "${tree_version}" ]] ||
    cix_die "cannot determine native source package name and version"

mkdir -p -- "${artifacts_dir}"
work_root="$(mktemp -d "${output_dir}/.${CIX_NATIVE_TARGET}.XXXXXXXXXX")"
readonly work_root
source_tree="${work_root}/${source_package}-${tree_version}"
readonly source_tree

cleanup() {
    if [[ -d "${work_root}" ]]; then
        rm -rf -- "${work_root}"
    fi
}
trap cleanup EXIT

cix_log "Assemble ${CIX_NATIVE_LABEL} native source package in ${work_root}"
mkdir -p -- "${source_tree}/debian"
rsync -a "${packaging_dir}/" "${source_tree}/debian/"
(
    cd "${work_root}"
    dpkg-source -b "$(basename "${source_tree}")"
)

mapfile -d '' -t dsc_files < <(
    find "${work_root}" -maxdepth 1 -type f -name "${source_package}_*.dsc" -print0
)
((${#dsc_files[@]} == 1)) ||
    cix_die "expected exactly one ${source_package} dsc; found ${#dsc_files[@]}"
dsc_file="${dsc_files[0]}"

source_date_epoch="$(git -C "${packaging_git}" log -1 --format=%ct)"
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

cix_log "${CIX_NATIVE_LABEL} package build complete"
find "${artifacts_dir}" -maxdepth 1 -type f -printf '    %p\n' | sort
