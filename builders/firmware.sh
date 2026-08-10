#!/usr/bin/env bash
# Generic firmware payload builder used by cix-build.

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

    ((CIX_TARGET_LFS)) || return 0
    for required in "${CIX_TARGET_REQUIRED_FILES[@]}"; do
        if cix_is_lfs_pointer "${source_dir}/${required}"; then
            cix_require_command git
            git -C "${source_git}" lfs version >/dev/null 2>&1 ||
                cix_die "Git LFS is required to materialize ${CIX_TARGET_DESCRIPTION}"
            source_rel="$(realpath --relative-to="${source_git}" -- "${source_dir}")"
            for pattern in "${CIX_TARGET_FILES[@]}"; do
                include+="${include:+,}${source_rel}/${pattern}"
            done
            cix_log "Fetch manifest-pinned Git LFS payloads for ${CIX_TARGET_DESCRIPTION}"
            git -C "${source_git}" lfs pull --include="${include}" --exclude=''
            return 0
        fi
    done
}

cix_validate_firmware_files() {
    local source_dir="$1"
    local file

    for file in "${CIX_TARGET_REQUIRED_FILES[@]}"; do
        [[ -s "${source_dir}/${file}" ]] ||
            cix_die "required firmware is missing: ${source_dir}/${file}"
        ! cix_is_lfs_pointer "${source_dir}/${file}" ||
            cix_die "firmware is still a Git LFS pointer: ${source_dir}/${file}"
    done
}

cix_firmware_package() {
    local packaging_dir="${CIX_WORKSPACE_ROOT}/${CIX_TARGET_DEBIAN}"
    local source_dir="${CIX_WORKSPACE_ROOT}/${CIX_TARGET_SOURCE}"
    local source_git="${CIX_WORKSPACE_ROOT}/${CIX_TARGET_SOURCE_GIT}"
    local dsc_file
    local pattern
    local source_date_epoch
    local source_tree
    local -a rsync_args=(-a)

    cix_sbuild_init
    if [[ "${CIX_ACTION}" == "clean" ]]; then
        cix_clean_files "${CIX_ARTIFACTS_DIR}" "${CIX_TARGET_DESCRIPTION} artifacts"
        return 0
    fi

    cix_require_command dpkg-parsechangelog dpkg-source find git grep realpath rsync sbuild tar
    cix_sbuild_validate_environment
    cix_validate_packaging "${packaging_dir}" "3.0 (quilt)"
    [[ -d "${source_dir}" ]] || cix_die "firmware source is missing: ${source_dir}"
    git -C "${source_git}" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
        cix_die "firmware source is not a Git worktree: ${source_git}"

    cix_materialize_firmware_lfs "${source_dir}" "${source_git}"
    cix_validate_firmware_files "${source_dir}"
    [[ -z "$(git -C "${source_git}" status --porcelain)" ]] ||
        cix_die "firmware source must be clean before packaging: ${source_git}"

    cix_read_debian_metadata "${packaging_dir}"
    mkdir -p -- "${CIX_ARTIFACTS_DIR}" "${CIX_OUTPUT_DIR}"
    CIX_PACKAGE_WORK_ROOT="$(mktemp -d "${CIX_OUTPUT_DIR}/.${CIX_TARGET}.XXXXXXXXXX")"
    trap cix_package_cleanup EXIT
    source_tree="${CIX_PACKAGE_WORK_ROOT}/${CIX_SOURCE_PACKAGE}-${CIX_UPSTREAM_VERSION}"
    cix_log "Assemble ${CIX_TARGET_DESCRIPTION} source package"
    mkdir -p -- "${source_tree}/${CIX_TARGET_PAYLOAD_DIR}"
    for pattern in "${CIX_TARGET_FILES[@]}"; do
        rsync_args+=(--include="${pattern}")
    done
    rsync_args+=(--exclude='*')
    rsync "${rsync_args[@]}" "${source_dir}/" \
        "${source_tree}/${CIX_TARGET_PAYLOAD_DIR}/"
    find "${source_tree}/${CIX_TARGET_PAYLOAD_DIR}" -type f -exec chmod 0644 -- {} +

    source_date_epoch="$(git -C "${source_git}" log -1 --format=%ct)"
    cix_create_orig_tar "${source_date_epoch}" "${source_tree}" "${CIX_PACKAGE_WORK_ROOT}"
    cix_create_quilt_dsc "${packaging_dir}" "${source_tree}" "${CIX_PACKAGE_WORK_ROOT}"
    dsc_file="$(cix_find_dsc "${CIX_PACKAGE_WORK_ROOT}")"
    cix_run_sbuild "${dsc_file}" "${source_date_epoch}"
    cix_log "${CIX_TARGET_DESCRIPTION} build complete"
    cix_print_files "${CIX_ARTIFACTS_DIR}"
}
