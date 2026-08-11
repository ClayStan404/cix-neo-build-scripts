#!/usr/bin/env bash
# Firmware source-package assembly for the Debian builder.

cix_is_lfs_pointer() {
    local file="$1"

    grep -aFqx -- "version https://git-lfs.github.com/spec/v1" "${file}" 2>/dev/null
}

cix_materialize_firmware_lfs() {
    local source_dir="$1"
    local source_git="$2"
    local source_rel
    local pattern
    local include=
    local required

    [[ "${TARGET[lfs]}" == 1 ]] || return 0
    for required in "${TARGET_REQUIRED_FILES[@]}"; do
        if cix_is_lfs_pointer "${source_dir}/${required}"; then
            cix_require_command git
            git -C "${source_git}" lfs version >/dev/null 2>&1 ||
                cix_die "Git LFS is required to materialize ${TARGET[description]}"
            source_rel="$(realpath --relative-to="${source_git}" -- "${source_dir}")"
            for pattern in "${TARGET_FILES[@]}"; do
                include+="${include:+,}${source_rel}/${pattern}"
            done
            cix_log "Fetch manifest-pinned Git LFS payloads for ${TARGET[description]}"
            git -C "${source_git}" lfs pull --include="${include}" --exclude=''
            return 0
        fi
    done
}

cix_validate_firmware_files() {
    local source_dir="$1"
    local file

    for file in "${TARGET_REQUIRED_FILES[@]}"; do
        [[ -s "${source_dir}/${file}" ]] ||
            cix_die "required firmware is missing: ${source_dir}/${file}"
        ! cix_is_lfs_pointer "${source_dir}/${file}" ||
            cix_die "firmware is still a Git LFS pointer: ${source_dir}/${file}"
    done
}

cix_debian_firmware_package() (
    local firmware_output="$1"
    local firmware_jobs="$2"
    local firmware_backend="$3"
    local packaging_dir="${CIX_ROOT}/${TARGET[debian]}"
    local source_dir="${CIX_ROOT}/${TARGET[source]}"
    local source_git="${CIX_ROOT}/${TARGET[source_git]}"
    local pattern
    local source_date_epoch
    local source_package
    local source_tree
    local upstream_version
    local work_root=
    local -a rsync_args=(-a)

    cix_validate_packaging "${packaging_dir}" "3.0 (quilt)"
    [[ -d "${source_dir}" ]] || cix_die "firmware source is missing: ${source_dir}"
    git -C "${source_git}" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
        cix_die "firmware source is not a Git worktree: ${source_git}"

    cix_materialize_firmware_lfs "${source_dir}" "${source_git}"
    cix_validate_firmware_files "${source_dir}"
    [[ -z "$(git -C "${source_git}" status --porcelain)" ]] ||
        cix_die "firmware source must be clean before packaging: ${source_git}"

    read -r source_package _ upstream_version < <(
        cix_debian_metadata "${packaging_dir}"
    )
    work_root="$(mktemp -d "${firmware_output}/.${TARGET[name]}.XXXXXXXXXX")"
    trap 'rm -rf -- "${work_root}"' EXIT
    source_tree="${work_root}/${source_package}-${upstream_version}"
    cix_log "Assemble ${TARGET[description]} source package"
    mkdir -p -- "${source_tree}/${TARGET[payload_dir]}"
    for pattern in "${TARGET_FILES[@]}"; do
        rsync_args+=(--include="${pattern}")
    done
    rsync_args+=(--exclude='*')
    rsync "${rsync_args[@]}" "${source_dir}/" \
        "${source_tree}/${TARGET[payload_dir]}/"
    find "${source_tree}/${TARGET[payload_dir]}" -type f -exec chmod 0644 -- {} +

    source_date_epoch="$(git -C "${source_git}" log -1 --format=%ct)"
    cix_create_orig_tar \
        "${source_package}" "${upstream_version}" "${source_date_epoch}" \
        "${source_tree}" "${work_root}"
    cix_add_debian_metadata "${packaging_dir}" "${source_tree}"
    cix_run_debian_backend \
        "${firmware_backend}" "${source_package}" "${source_tree}" \
        "${source_date_epoch}" "${work_root}" "${firmware_output}" \
        "${firmware_jobs}"
)
