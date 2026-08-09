#!/usr/bin/env bash
# Build native ARM64 kernel Debian packages with the kernel bindeb-pkg target.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=framework.sh
source "${SCRIPT_DIR}/framework.sh"

action="build"
board="${CIX_BOARD:-evb}"
build_mode="${CIX_BUILD_MODE:-release}"
distribution="${CIX_BUILD_DISTRIBUTION:-trixie}"
docker_mode="${CIX_DOCKER_MODE:-none}"
jobs="${CIX_BUILD_JOBS:-$(cix_default_jobs)}"
nexus_site="${CIX_NEXUS_SITE:-zj}"
output_dir="${CIX_OUTPUT_DIR:-${CIX_WORKSPACE_ROOT}/output}/kernel"
package_version="${CIX_KERNEL_PACKAGE_VERSION:-}"

usage() {
    cat <<'EOF'
Usage: build-kernel.sh [OPTIONS] [build|clean]

Build native ARM64 kernel Debian packages with make bindeb-pkg.

Options:
  --board NAME           Board configuration selector (default: evb)
  --build-mode MODE      release or debug (default: release)
  --distribution SUITE  Package changelog distribution (default: trixie)
  --docker-mode MODE     none or docker (default: none)
  --jobs COUNT           Parallel make jobs
  --nexus SITE           sh, zj, wuh, szv, ksh, wux, release, or public
  --output-dir PATH      Kernel build and package output directory
  --package-version VER  Explicit KDEB_PKGVERSION value
  -h, --help             Show this help
EOF
}

while (($#)); do
    case "$1" in
        build|clean)
            action="$1"
            shift
            ;;
        --board)
            (($# >= 2)) || cix_die "$1 requires a value"
            board="$2"
            shift 2
            ;;
        --build-mode)
            (($# >= 2)) || cix_die "$1 requires a value"
            build_mode="$2"
            shift 2
            ;;
        --distribution)
            (($# >= 2)) || cix_die "$1 requires a value"
            distribution="$2"
            shift 2
            ;;
        --docker-mode)
            (($# >= 2)) || cix_die "$1 requires a value"
            docker_mode="$2"
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
        --package-version)
            (($# >= 2)) || cix_die "$1 requires a value"
            package_version="$2"
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
[[ "${build_mode}" == "release" || "${build_mode}" == "debug" ]] ||
    cix_die "invalid build mode: ${build_mode}"
[[ "${docker_mode}" == "none" || "${docker_mode}" == "docker" ]] ||
    cix_die "invalid Docker mode: ${docker_mode}"
[[ "${distribution}" =~ ^[a-zA-Z0-9][a-zA-Z0-9.+_-]*$ ]] ||
    cix_die "invalid distribution: ${distribution}"

readonly kernel_source="${CIX_WORKSPACE_ROOT}/sources/linux"
readonly kernel_patch_dir="${CIX_WORKSPACE_ROOT}/debian/kernel/patches"
readonly kernel_patch_series="${kernel_patch_dir}/series"
build_dir="$(realpath -m -- "${output_dir}/build")"
readonly build_dir
[[ -f "${kernel_source}/Makefile" ]] || cix_die "kernel source is missing: ${kernel_source}"

cix_require_command make fakeroot dpkg-buildpackage

if [[ "${action}" == "clean" ]]; then
    if [[ -d "${build_dir}" ]]; then
        cix_log "Clean kernel build directory ${build_dir}"
        make -C "${kernel_source}" O="${build_dir}" ARCH=arm64 clean
    else
        cix_log "Kernel build directory does not exist: ${build_dir}"
    fi
    exit 0
fi

cix_require_command git
[[ -f "${kernel_patch_series}" ]] ||
    cix_die "kernel patch series is missing: ${kernel_patch_series}"
[[ "$(git -C "${kernel_source}" rev-parse --is-inside-work-tree)" == "true" ]] ||
    cix_die "kernel source is not a Git worktree: ${kernel_source}"
if [[ -n "$(git -C "${kernel_source}" status --porcelain)" ]]; then
    cix_die "kernel source must be clean before creating the patched build worktree"
fi

mkdir -p -- "${build_dir}" "${output_dir}"

kernel_worktree_root="$(mktemp -d "${output_dir}/.kernel-source.XXXXXXXXXX")"
kernel_build_source="${kernel_worktree_root}/linux"
kernel_worktree_registered=0

cleanup_kernel_worktree() {
    local exit_status=$?

    trap - EXIT
    if ((kernel_worktree_registered)); then
        if ! git -C "${kernel_source}" worktree remove --force \
            "${kernel_build_source}"; then
            cix_log "Failed to remove temporary kernel worktree: ${kernel_build_source}"
            ((exit_status != 0)) || exit_status=1
        fi
    fi
    if [[ -d "${kernel_worktree_root}" ]]; then
        rmdir -- "${kernel_worktree_root}" 2>/dev/null || true
    fi
    exit "${exit_status}"
}
trap cleanup_kernel_worktree EXIT

kernel_commit="$(git -C "${kernel_source}" rev-parse HEAD)"
cix_log "Create patched kernel worktree at ${kernel_commit}"
git -C "${kernel_source}" worktree add --quiet --detach \
    "${kernel_build_source}" "${kernel_commit}"
kernel_worktree_registered=1

patch_count=0
while IFS= read -r patch_entry || [[ -n "${patch_entry}" ]]; do
    patch_entry="${patch_entry%%#*}"
    patch_entry="${patch_entry#"${patch_entry%%[![:space:]]*}"}"
    patch_entry="${patch_entry%"${patch_entry##*[![:space:]]}"}"
    [[ -n "${patch_entry}" ]] || continue
    [[ "${patch_entry}" != *[[:space:]]* ]] ||
        cix_die "kernel patch series options are not supported: ${patch_entry}"

    patch_file="$(realpath -m -- "${kernel_patch_dir}/${patch_entry}")"
    [[ "${patch_file}" == "${kernel_patch_dir}/"* ]] ||
        cix_die "kernel patch escapes patch directory: ${patch_entry}"
    [[ -f "${patch_file}" ]] || cix_die "kernel patch is missing: ${patch_file}"

    cix_log "Apply kernel patch: ${patch_entry}"
    git -C "${kernel_build_source}" apply --check "${patch_file}"
    git -C "${kernel_build_source}" apply "${patch_file}"
    ((patch_count += 1))
done < "${kernel_patch_series}"
((patch_count > 0)) || cix_die "kernel patch series is empty: ${kernel_patch_series}"

config_targets=(defconfig cix.config cix_docker.config)
case "${board}" in
    cloudbook|emu|fpga)
        config_targets+=("cix_${board}.config")
        ;;
esac
if [[ "${docker_mode}" == "docker" ]]; then
    config_targets+=(cix_redroid.config)
fi
if [[ "${build_mode}" == "debug" ]]; then
    config_targets+=(cix_debug.config)
fi

for config_target in "${config_targets[@]}"; do
    [[ -f "${kernel_build_source}/arch/arm64/configs/${config_target}" ]] ||
        cix_die "kernel-owned config is missing: ${config_target}"
done

export CIX_NEXUS_SITE="${nexus_site}"
export CCACHE_DIR="${CIX_SBUILD_CCACHE_DIR:-${XDG_CACHE_HOME:-${HOME}/.cache}/cix-neo-sbuild/ccache}"
if command -v ccache >/dev/null && [[ -d /usr/lib/ccache ]]; then
    export PATH="/usr/lib/ccache:${PATH}"
fi

cix_log "Configure kernel with: ${config_targets[*]}"
make -C "${kernel_build_source}" \
    O="${build_dir}" \
    ARCH=arm64 \
    -j"${jobs}" \
    "${config_targets[@]}"

package_args=(
    ARCH=arm64
    LOCALVERSION=-generic
    KDEB_CHANGELOG_DIST="${distribution}"
    KDEB_SOURCENAME=cix-linux
)
if [[ -n "${package_version}" ]]; then
    package_args+=(KDEB_PKGVERSION="${package_version}")
fi

cix_log "Build kernel Debian packages in ${output_dir}"
make -C "${kernel_build_source}" \
    O="${build_dir}" \
    -j"${jobs}" \
    "${package_args[@]}" \
    bindeb-pkg

cix_log "Kernel package build complete"
find "${output_dir}" -maxdepth 1 -type f -name '*.deb' -printf '    %p\n' | sort
