#!/usr/bin/env bash
# Shared isolated-worktree support for native EDK2 direct flows.

cix_edk2_remove_workspace() {
    local source_root="$1"
    local build_output="$2"
    local source_edk2="${source_root}/edk2"
    local work_root="${build_output}/work"
    local dependency

    while IFS= read -r dependency; do
        cix_remove_git_worktree \
            "${source_edk2}/${dependency}" \
            "${work_root}/edk2/${dependency}"
    done < <(
        git -C "${source_edk2}" ls-files --stage |
            awk '$1 == "160000" {print $4}'
    )

    cix_remove_git_worktree "${source_root}/edk2" "${work_root}/edk2"
    cix_remove_git_worktree \
        "${source_root}/edk2-platforms" "${work_root}/edk2-platforms"
    if [[ -d "${source_root}/tools/acpica" ]]; then
        cix_remove_git_worktree \
            "${source_root}/tools/acpica" "${work_root}/tools/acpica"
    fi

    if [[ -d "${work_root}" ]]; then
        find "${work_root}" -mindepth 1 -delete
        rmdir "${work_root}"
    fi
}

cix_edk2_prepare_workspace() {
    local source_root="$1"
    local build_output="$2"
    local source_edk2="${source_root}/edk2"
    local work_root="${build_output}/work"
    local dependency
    local dependency_target

    cix_edk2_remove_workspace "${source_root}" "${build_output}"
    mkdir -p -- "${work_root}"

    git -C "${source_root}/edk2" worktree add --detach \
        "${work_root}/edk2" HEAD
    git -C "${source_root}/edk2-platforms" worktree add --detach \
        "${work_root}/edk2-platforms" HEAD
    if [[ -d "${source_root}/tools/acpica" ]]; then
        mkdir -p -- "${work_root}/tools"
        git -C "${source_root}/tools/acpica" worktree add --detach \
            "${work_root}/tools/acpica" HEAD
    fi

    while IFS= read -r dependency; do
        dependency_target="${work_root}/edk2/${dependency}"
        if [[ -d "${dependency_target}" ]]; then
            rmdir "${dependency_target}"
        fi
        mkdir -p -- "$(dirname "${dependency_target}")"
        git -C "${source_edk2}/${dependency}" worktree add --detach \
            "${dependency_target}" HEAD
    done < <(
        git -C "${source_edk2}" ls-files --stage |
            awk '$1 == "160000" {print $4}'
    )
}

cix_edk2_build_host_tools() {
    local edk2_source="$1"
    local build_jobs="$2"
    local build_log="$3"

    cix_require_command tail
    cix_log "Build EDK2 host tools with ${build_jobs} jobs"
    if ! make -s -C "${edk2_source}/BaseTools" \
        -j"${build_jobs}" \
        BUILD_LFLAGS=-no-pie \
        EXTRA_LDFLAGS=-no-pie >"${build_log}" 2>&1; then
        tail -n 200 "${build_log}" >&2
        cix_die "EDK2 host tools failed; full log: ${build_log}"
    fi
}
