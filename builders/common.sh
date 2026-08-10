#!/usr/bin/env bash
# Shared primitives for the CIX Neo build command.

CIX_ROOT="$(realpath "$(dirname "${BASH_SOURCE[0]}")/../..")"
CIX_SUITE=trixie
# These constants are consumed by scripts that source this file.
# shellcheck disable=SC2034
readonly CIX_ROOT CIX_SUITE

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

cix_validate_host() {
    local architecture
    local ID
    local VERSION_ID

    [[ -r /etc/os-release ]] || cix_die "/etc/os-release is missing"
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ "${ID:-}" == "debian" && "${VERSION_ID:-}" == "13" ]] ||
        cix_die "Debian 13 build host required; detected ${ID:-unknown} ${VERSION_ID:-unknown}"

    cix_require_command dpkg
    architecture="$(dpkg --print-architecture)"
    [[ "${architecture}" == "arm64" ]] ||
        cix_die "native ARM64 host required; detected ${architecture}"
}

cix_clean_artifacts() {
    local directory="$1"

    if [[ -d "${directory}" ]]; then
        cix_log "Clean artifacts in ${directory}"
        find "${directory}" -mindepth 1 -maxdepth 1 \
            \( -type f -o -type l \) -delete
    fi
}
