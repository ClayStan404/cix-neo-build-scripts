#!/usr/bin/env bash
# Build the latest supported stable Linux release with the CIX patch set.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=framework.sh
source "${SCRIPT_DIR}/framework.sh"

action="build"
distribution="${CIX_BUILD_DISTRIBUTION:-trixie}"
jobs="${CIX_BUILD_JOBS:-$(cix_default_jobs)}"
nexus_site="${CIX_NEXUS_SITE:-zj}"
output_dir="${CIX_OUTPUT_DIR:-${CIX_WORKSPACE_ROOT}/output}/kernel-stable"
kernel_version="${CIX_STABLE_KERNEL_VERSION:-}"
kernel_series="${CIX_STABLE_KERNEL_SERIES:-}"
tarball_url="${CIX_STABLE_KERNEL_TARBALL_URL:-}"
package_version="${CIX_STABLE_KERNEL_PACKAGE_VERSION:-}"

usage() {
    cat <<'EOF'
Usage: build-kernel-stable.sh [OPTIONS] [build|clean]

Build the stable kernel selected by cix-linux-kernel with its native
make bindeb-pkg flow and the manifest-managed CIX patch set.

Options:
  --distribution SUITE  Package changelog distribution (default: trixie)
  --jobs COUNT           Parallel make jobs
  --kernel-version VER   Override the cix-linux-kernel default version
  --kernel-series VER    Override the patch/kernel series (for example: 7.0)
  --nexus SITE           sh, zj, wuh, szv, ksh, wux, release, or public
  --output-dir PATH      Stable-kernel work and artifact directory
  --package-version VER  Explicit KDEB_PKGVERSION value
  --tarball-url URL      Override the kernel.org tarball URL
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
        --kernel-version)
            (($# >= 2)) || cix_die "$1 requires a value"
            kernel_version="$2"
            shift 2
            ;;
        --kernel-series)
            (($# >= 2)) || cix_die "$1 requires a value"
            kernel_series="$2"
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
        --package-version)
            (($# >= 2)) || cix_die "$1 requires a value"
            package_version="$2"
            shift 2
            ;;
        --tarball-url)
            (($# >= 2)) || cix_die "$1 requires a value"
            tarball_url="$2"
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
[[ -z "${kernel_version}" || "${kernel_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    cix_die "invalid stable kernel version: ${kernel_version}"
[[ -z "${kernel_series}" || "${kernel_series}" =~ ^[0-9]+\.[0-9]+$ ]] ||
    cix_die "invalid stable kernel series: ${kernel_series}"

if [[ -n "${kernel_version}" && -z "${kernel_series}" ]]; then
    kernel_series="${kernel_version%.*}"
fi

readonly stable_source="${CIX_WORKSPACE_ROOT}/sources/linux-stable"
readonly patch_source="${CIX_WORKSPACE_ROOT}/sources/linux-main"
readonly upstream_builder="${stable_source}/native/build-kernel-native.sh"
output_dir="$(realpath -m -- "${output_dir}")"
readonly output_dir
readonly work_dir="${output_dir}/work"
readonly artifacts_dir="${output_dir}/artifacts"
readonly patch_remote="${work_dir}/.cix-linux-main.git"

[[ -x "${upstream_builder}" ]] ||
    cix_die "stable kernel builder is missing: ${upstream_builder}"
[[ -d "${patch_source}/.git" || -f "${patch_source}/.git" ]] ||
    cix_die "CIX stable kernel patch source is missing: ${patch_source}"

if [[ "${action}" == "clean" ]]; then
    if [[ -d "${artifacts_dir}" ]]; then
        cix_log "Remove stable kernel artifacts from ${artifacts_dir}"
        find "${artifacts_dir}" -mindepth 1 -maxdepth 1 -type f -delete
    fi
    if [[ -d "${work_dir}" ]]; then
        cix_log "Remove generated stable kernel work files; preserve tarball cache"
        find "${work_dir}" -mindepth 1 -maxdepth 1 \
            ! -name 'linux-*.tar.xz' -delete
    fi
    exit 0
fi

cix_require_command \
    bc bison curl dpkg-buildpackage fakeroot flex gcc git make nproc openssl \
    pahole realpath rsync tar xz
if [[ -n "$(git -C "${stable_source}" status --porcelain)" ]]; then
    cix_die "stable kernel build harness must be clean: ${stable_source}"
fi
if [[ -n "$(git -C "${patch_source}" status --porcelain)" ]]; then
    cix_die "stable kernel patch source must be clean: ${patch_source}"
fi

mkdir -p -- "${work_dir}" "${artifacts_dir}"
patch_commit="$(git -C "${patch_source}" rev-parse HEAD)"
readonly patch_commit

if [[ ! -d "${patch_remote}" ]]; then
    git init --quiet --bare "${patch_remote}"
fi
git -C "${patch_remote}" fetch --quiet --force --no-tags \
    "${patch_source}" "${patch_commit}"
git -C "${patch_remote}" update-ref refs/heads/main "${patch_commit}"

export CIX_NEXUS_SITE="${nexus_site}"
export KDEB_CHANGELOG_DIST="${distribution}"
export OMP_NUM_THREADS="${jobs}"
export OMP_THREAD_LIMIT="${jobs}"
export OUTPUT_DIR="${artifacts_dir}"
export PATCH_BRANCH=main
export PATCH_REMOTE="${patch_remote}"
export WORK_DIR="${work_dir}"
[[ -z "${kernel_version}" ]] || export KERNEL_VERSION="${kernel_version}"
[[ -z "${kernel_series}" ]] || export KERNEL_SERIES="${kernel_series}"
[[ -z "${tarball_url}" ]] || export KERNEL_TARBALL_URL="${tarball_url}"
[[ -z "${package_version}" ]] || export KDEB_PKGVERSION="${package_version}"

cix_log "Build stable CIX kernel from ${stable_source}"
cix_log "Use manifest-managed CIX patches at ${patch_commit}"
(
    cd "${stable_source}/native"
    "${upstream_builder}"
)
