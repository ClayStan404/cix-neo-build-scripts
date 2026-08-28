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

cix_prepare_host_ccache() {
    cix_require_command ccache
    [[ -d /usr/lib/ccache ]] ||
        cix_die "ccache compiler wrappers are missing: /usr/lib/ccache"

    CCACHE_DIR="${HOME}/.cache/cix-neo-sbuild/ccache"
    CCACHE_UMASK=000
    PATH="/usr/lib/ccache:${PATH}"
    export CCACHE_DIR CCACHE_UMASK PATH
    mkdir -p -- "${CCACHE_DIR}"
    ccache --set-config 'max_size=20G'
    cix_log "Use ccache at ${CCACHE_DIR}"
}

cix_require_free_gib() {
    local path="$1"
    local required_gib="$2"
    local purpose="$3"
    local available_kib
    local mount_point
    local required_kib="$((required_gib * 1024 * 1024))"

    cix_require_command awk df
    read -r available_kib mount_point < <(
        df -Pk -- "${path}" | awk 'END { print $4, $6 }'
    )
    [[ "${available_kib}" =~ ^[0-9]+$ ]] ||
        cix_die "cannot determine free disk space for ${path}"
    ((available_kib >= required_kib)) ||
        cix_die "${purpose} requires at least ${required_gib} GiB free on ${mount_point}; available: $((available_kib / 1024 / 1024)) GiB"
}

cix_clean_artifacts() {
    local directory="$1"

    if [[ -d "${directory}" ]]; then
        cix_log "Clean artifacts in ${directory}"
        find "${directory}" -mindepth 1 -maxdepth 1 \
            \( -type f -o -type l \) -delete
    fi
}

cix_validate_edk2_inputs() {
    local edk2_source="$1"
    local dependency

    while IFS= read -r dependency; do
        git -C "${edk2_source}/${dependency}" rev-parse \
            --is-inside-work-tree >/dev/null 2>&1 ||
            cix_die "EDK2 dependency is not synced; run repo sync: ${dependency}"
    done < <(
        git -C "${edk2_source}" ls-files --stage |
            awk '$1 == "160000" {print $4}'
    )
}

cix_remove_git_worktree() {
    local repository="$1"
    local worktree="$2"

    if git -C "${repository}" worktree list --porcelain |
        awk -v worktree="${worktree}" \
            '$1 == "worktree" && substr($0, 10) == worktree {found = 1}
             END {exit !found}'; then
        git -C "${repository}" worktree remove --force "${worktree}"
    fi
    git -C "${repository}" worktree prune
}

cix_apply_patch() {
    local repository="$1"
    local patch_file="$2"
    local whitespace_mode="${3:-exact}"
    local -a apply_options=(--whitespace=nowarn)

    if [[ "${whitespace_mode}" == "ignore-space-change" ]]; then
        apply_options+=(--ignore-space-change)
    elif [[ "${whitespace_mode}" != "exact" ]]; then
        cix_die "unsupported patch whitespace mode: ${whitespace_mode}"
    fi

    if git -C "${repository}" apply --check "${apply_options[@]}" "${patch_file}"; then
        cix_log "Apply $(basename "${patch_file}")"
        git -C "${repository}" apply "${apply_options[@]}" "${patch_file}"
    elif git -C "${repository}" apply --reverse --check \
        "${apply_options[@]}" "${patch_file}"; then
        cix_log "Skip patch already present upstream: $(basename "${patch_file}")"
    else
        cix_die "patch does not apply cleanly: ${patch_file}"
    fi
}

cix_validate_patch_series_with_mode() (
    local repository="$1"
    local whitespace_mode="$2"
    shift 2
    local index_file
    local patch_file
    local -a apply_options=(--cached --whitespace=nowarn)

    if [[ "${whitespace_mode}" == "ignore-space-change" ]]; then
        apply_options+=(--ignore-space-change)
    elif [[ "${whitespace_mode}" != "exact" ]]; then
        cix_die "unsupported patch whitespace mode: ${whitespace_mode}"
    fi

    git -C "${repository}" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
        cix_die "patch source is not a Git worktree: ${repository}"
    (($# > 0)) || return 0

    index_file="$(mktemp)"
    rm -- "${index_file}"
    trap 'rm -f -- "${index_file}"' EXIT
    GIT_INDEX_FILE="${index_file}" git -C "${repository}" read-tree HEAD

    for patch_file in "$@"; do
        [[ -s "${patch_file}" ]] || cix_die "patch is missing: ${patch_file}"
        if GIT_INDEX_FILE="${index_file}" git -C "${repository}" apply \
            --check "${apply_options[@]}" "${patch_file}"; then
            GIT_INDEX_FILE="${index_file}" git -C "${repository}" apply \
                "${apply_options[@]}" "${patch_file}"
        elif GIT_INDEX_FILE="${index_file}" git -C "${repository}" apply \
            --reverse --check "${apply_options[@]}" "${patch_file}"; then
            cix_log "Preflight: patch is already present upstream: $(basename "${patch_file}")"
        else
            cix_die "patch does not apply cleanly: ${patch_file}"
        fi
    done
)

cix_validate_patch_series() {
    local repository="$1"
    shift

    cix_validate_patch_series_with_mode "${repository}" exact "$@"
}
