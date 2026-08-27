#!/usr/bin/env bash
# Global cleanup operations for registered build targets and persistent caches.

cix_global_cleanup_preflight() {
    local name
    local output_dir
    local output_root="${CIX_ROOT}/output"

    [[ ! -L "${output_root}" ]] ||
        cix_die "output root must not be a symlink: ${output_root}"
    [[ ! -e "${output_root}" || -d "${output_root}" ]] ||
        cix_die "output root is not a directory: ${output_root}"

    for name in "$@"; do
        output_dir="${output_root}/${name}"
        [[ ! -L "${output_dir}" ]] ||
            cix_die "target output must not be a symlink: ${output_dir}"
        [[ ! -e "${output_dir}" || -d "${output_dir}" ]] ||
            cix_die "target output is not a directory: ${output_dir}"
    done
}

cix_remove_registered_outputs() {
    local name
    local output_dir
    local output_entry
    local output_root="${CIX_ROOT}/output"

    cix_require_command find rmdir
    for name in "$@"; do
        output_dir="${output_root}/${name}"
        [[ -d "${output_dir}" ]] || continue
        cix_log "Remove registered target directory ${output_dir}"
        find "${output_dir}" -xdev -mindepth 1 -delete
        rmdir -- "${output_dir}"
    done

    [[ -d "${output_root}" ]] || return 0
    while IFS= read -r -d '' output_entry; do
        cix_log "Preserve unregistered output entry ${output_entry}"
    done < <(find "${output_root}" -mindepth 1 -maxdepth 1 -print0)
}

cix_persistent_build_cache_preflight() {
    local apt_archives_dir="${HOME}/.cache/cix-neo-sbuild/apt-archives"
    local ccache_dir="${HOME}/.cache/cix-neo-sbuild/ccache"
    local cache_dir

    for cache_dir in "${ccache_dir}" "${apt_archives_dir}"; do
        [[ ! -L "${cache_dir}" ]] ||
            cix_die "build cache must not be a symlink: ${cache_dir}"
        [[ ! -e "${cache_dir}" || -d "${cache_dir}" ]] ||
            cix_die "build cache is not a directory: ${cache_dir}"
    done

    [[ ! -d "${ccache_dir}" ]] || cix_require_command ccache
    if [[ -d "${apt_archives_dir}" ]]; then
        cix_require_command find
        if [[ ! -w "${apt_archives_dir}" ]]; then
            cix_require_command unshare
            unshare --user --map-auto --setuid 0 --setgid 0 \
                test -w "${apt_archives_dir}" ||
                cix_die "sbuild APT cache is not writable in its user namespace"
        fi
    fi
}

cix_clear_persistent_build_caches() {
    local apt_archives_dir="${HOME}/.cache/cix-neo-sbuild/apt-archives"
    local ccache_dir="${HOME}/.cache/cix-neo-sbuild/ccache"

    cix_persistent_build_cache_preflight
    if [[ -d "${ccache_dir}" ]]; then
        cix_log "Clear compiler cache ${ccache_dir}"
        CCACHE_DIR="${ccache_dir}" ccache --clear
    fi

    if [[ -d "${apt_archives_dir}" ]]; then
        cix_log "Clear sbuild APT archive cache ${apt_archives_dir}"
        if [[ -w "${apt_archives_dir}" ]]; then
            find "${apt_archives_dir}" -xdev -mindepth 1 -delete
        else
            unshare --user --map-auto --setuid 0 --setgid 0 \
                find "${apt_archives_dir}" -xdev -mindepth 1 -delete
        fi
    fi
}
