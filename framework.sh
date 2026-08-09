#!/usr/bin/env bash
# Shared helpers for CIX Neo module build scripts.

if [[ -n "${CIX_NEO_FRAMEWORK_LOADED:-}" ]]; then
    return 0
fi
readonly CIX_NEO_FRAMEWORK_LOADED=1

CIX_BUILD_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CIX_BUILD_SCRIPTS_DIR
CIX_WORKSPACE_ROOT="$(cd "${CIX_BUILD_SCRIPTS_DIR}/.." && pwd)"
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

cix_validate_nexus_site() {
    case "$1" in
        sh|zj|wuh|szv|ksh|wux|release|public)
            ;;
        *)
            cix_die "invalid Nexus site: $1"
            ;;
    esac
}

cix_validate_native_arm64() {
    cix_require_command dpkg
    [[ "$(dpkg --print-architecture)" == "arm64" ]] ||
        cix_die "native ARM64 host required; detected $(dpkg --print-architecture)"
}

cix_validate_positive_integer() {
    [[ "$2" =~ ^[1-9][0-9]*$ ]] || cix_die "$1 must be a positive integer: $2"
}

cix_default_jobs() {
    if command -v nproc >/dev/null; then
        nproc
    else
        printf '1\n'
    fi
}
