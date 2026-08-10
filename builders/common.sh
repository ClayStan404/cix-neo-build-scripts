#!/usr/bin/env bash
# Shared primitives for the CIX Neo build command.

if [[ -n "${CIX_COMMON_LOADED:-}" ]]; then
    return 0
fi
readonly CIX_COMMON_LOADED=1

CIX_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly CIX_SCRIPTS_DIR
CIX_WORKSPACE_ROOT="$(cd "${CIX_SCRIPTS_DIR}/.." && pwd)"
readonly CIX_WORKSPACE_ROOT
export CIX_WORKSPACE_ROOT

cix_log() {
    printf '>>> %s\n' "$*"
}

cix_die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

cix_require_command() {
    local command_name

    for command_name in "$@"; do
        command -v "${command_name}" >/dev/null ||
            cix_die "required command is unavailable: ${command_name}"
    done
}

cix_default_jobs() {
    if command -v nproc >/dev/null; then
        nproc
    else
        printf '1\n'
    fi
}

cix_validate_positive_integer() {
    [[ "$2" =~ ^[1-9][0-9]*$ ]] ||
        cix_die "$1 must be a positive integer: $2"
}

cix_validate_host() {
    local architecture
    local ID
    local os_id
    local os_version
    local VERSION_ID

    [[ -r /etc/os-release ]] || cix_die "/etc/os-release is missing"
    # shellcheck disable=SC1091
    source /etc/os-release
    os_id="${ID:-}"
    os_version="${VERSION_ID:-}"
    [[ "${os_id}" == "debian" && "${os_version}" == "13" ]] ||
        cix_die "Debian 13 build host required; detected ${os_id:-unknown} ${os_version:-unknown}"

    cix_require_command dpkg
    architecture="$(dpkg --print-architecture)"
    [[ "${architecture}" == "arm64" ]] ||
        cix_die "native ARM64 host required; detected ${architecture}"
}

cix_validate_config() {
    case "${CIX_NEXUS}" in
        sh|zj|wuh|szv|ksh|wux|release|public)
            ;;
        *)
            cix_die "invalid Nexus site: ${CIX_NEXUS}"
            ;;
    esac

    cix_validate_positive_integer jobs "${CIX_JOBS}"
    [[ "${CIX_DISTRIBUTION}" =~ ^[a-zA-Z0-9][a-zA-Z0-9.+_-]*$ ]] ||
        cix_die "invalid distribution: ${CIX_DISTRIBUTION}"
    [[ "${CIX_BUILD_MODE}" == "release" || "${CIX_BUILD_MODE}" == "debug" ]] ||
        cix_die "invalid build mode: ${CIX_BUILD_MODE}"
    [[ "${CIX_DOCKER_MODE}" == "none" || "${CIX_DOCKER_MODE}" == "docker" ]] ||
        cix_die "invalid Docker mode: ${CIX_DOCKER_MODE}"
    [[ -z "${CIX_KERNEL_VERSION}" || "${CIX_KERNEL_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
        cix_die "invalid stable kernel version: ${CIX_KERNEL_VERSION}"
    [[ -z "${CIX_KERNEL_SERIES}" || "${CIX_KERNEL_SERIES}" =~ ^[0-9]+\.[0-9]+$ ]] ||
        cix_die "invalid stable kernel series: ${CIX_KERNEL_SERIES}"
}

cix_clean_files() {
    local directory="$1"
    local label="$2"

    if [[ -d "${directory}" ]]; then
        cix_log "Remove ${label} from ${directory}"
        find "${directory}" -mindepth 1 -maxdepth 1 -type f -delete
    fi
}

cix_print_files() {
    local directory="$1"

    find "${directory}" -maxdepth 1 -type f -printf '    %p\n' | sort
}
