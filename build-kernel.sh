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

cix_validate_native_arm64
cix_validate_nexus_site "${nexus_site}"
cix_validate_positive_integer "jobs" "${jobs}"
[[ "${build_mode}" == "release" || "${build_mode}" == "debug" ]] ||
    cix_die "invalid build mode: ${build_mode}"
[[ "${docker_mode}" == "none" || "${docker_mode}" == "docker" ]] ||
    cix_die "invalid Docker mode: ${docker_mode}"
[[ "${distribution}" =~ ^[a-zA-Z0-9][a-zA-Z0-9.+_-]*$ ]] ||
    cix_die "invalid distribution: ${distribution}"

readonly kernel_source="${CIX_WORKSPACE_ROOT}/sources/linux"
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

mkdir -p -- "${build_dir}"

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
    [[ -f "${kernel_source}/arch/arm64/configs/${config_target}" ]] ||
        cix_die "kernel-owned config is missing: ${config_target}"
done

export CIX_NEXUS_SITE="${nexus_site}"
export CCACHE_DIR="${CIX_SBUILD_CCACHE_DIR:-${XDG_CACHE_HOME:-${HOME}/.cache}/cix-neo-sbuild/ccache}"
if command -v ccache >/dev/null && [[ -d /usr/lib/ccache ]]; then
    export PATH="/usr/lib/ccache:${PATH}"
fi

cix_log "Configure kernel with: ${config_targets[*]}"
make -C "${kernel_source}" \
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
make -C "${kernel_source}" \
    O="${build_dir}" \
    -j"${jobs}" \
    "${package_args[@]}" \
    bindeb-pkg

cix_log "Kernel package build complete"
find "${output_dir}" -maxdepth 1 -type f -name '*.deb' -printf '    %p\n' | sort
