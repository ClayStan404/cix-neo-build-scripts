#!/usr/bin/env bash
# Manifest-managed payload assembly for the Debian builder.

cix_is_lfs_pointer() {
    local file="$1"

    grep -aFqx -- "version https://git-lfs.github.com/spec/v1" "${file}" 2>/dev/null
}

cix_payload_source() {
    printf '%s\n' "${1%%=*}"
}

cix_payload_destination() {
    local specification="$1"
    local source

    source="$(cix_payload_source "${specification}")"
    if [[ "${specification}" == *=* ]]; then
        printf '%s\n' "${specification#*=}"
    else
        printf '%s/%s\n' "${TARGET[payload_dir]}" "$(basename "${source}")"
    fi
}

cix_materialize_payload_lfs() {
    local source_dir="$1"
    local source_git="$2"
    local file
    local include=
    local item
    local item_path
    local lfs_url
    local needs_pull=0
    local source_rel

    [[ "${TARGET[lfs]}" == 1 ]] || return 0
    for item in "${TARGET_FILES[@]}"; do
        item_path="$(cix_payload_source "${item}")"
        while IFS= read -r -d '' file; do
            if cix_is_lfs_pointer "${file}"; then
                needs_pull=1
                break 2
            fi
        done < <(find "${source_dir}/${item_path}" -type f -print0)
    done
    ((needs_pull == 1)) || return 0

    cix_require_command git
    git -C "${source_git}" lfs version >/dev/null 2>&1 ||
        cix_die "Git LFS is required to materialize ${TARGET[description]}"
    source_rel="$(realpath --relative-to="${source_git}" -- "${source_dir}")"
    for item in "${TARGET_FILES[@]}"; do
        item_path="$(cix_payload_source "${item}")"
        if [[ -d "${source_dir}/${item_path}" ]]; then
            item_path="${item_path}/**"
        fi
        include+="${include:+,}${source_rel}/${item_path}"
    done
    lfs_url="$(git -C "${source_git}" config --get lfs.url || true)"
    if [[ -z "${lfs_url}" ]]; then
        lfs_url="https://artifacts.cixtech.com/repository/gerrit-lfs/info/lfs"
    fi
    cix_log "Fetch manifest-pinned Git LFS payloads for ${TARGET[description]}"
    git -C "${source_git}" -c "lfs.url=${lfs_url}" \
        lfs pull --include="${include}" --exclude=''
}

cix_validate_payload() {
    local source_dir="$1"
    local file
    local item
    local item_path

    for item in "${TARGET_FILES[@]}"; do
        item_path="$(cix_payload_source "${item}")"
        [[ -e "${source_dir}/${item_path}" ]] ||
            cix_die "payload source is missing: ${source_dir}/${item_path}"
        while IFS= read -r -d '' file; do
            ! cix_is_lfs_pointer "${file}" ||
                cix_die "payload is still a Git LFS pointer: ${file}"
        done < <(find "${source_dir}/${item_path}" -type f -print0)
    done
    for file in "${TARGET_REQUIRED_FILES[@]}"; do
        [[ -s "${source_dir}/${file}" ]] ||
            cix_die "required payload is missing: ${source_dir}/${file}"
        ! cix_is_lfs_pointer "${source_dir}/${file}" ||
            cix_die "payload is still a Git LFS pointer: ${source_dir}/${file}"
    done
}

cix_stage_payload() {
    local source_dir="$1"
    local source_tree="$2"
    local destination
    local item
    local item_path

    for item in "${TARGET_FILES[@]}"; do
        item_path="$(cix_payload_source "${item}")"
        destination="${source_tree}/$(cix_payload_destination "${item}")"
        if [[ -d "${source_dir}/${item_path}" ]]; then
            mkdir -p -- "${destination}"
            rsync -a "${source_dir}/${item_path}/" "${destination}/"
        else
            mkdir -p -- "$(dirname "${destination}")"
            rsync -a "${source_dir}/${item_path}" "${destination}"
        fi
    done
}

cix_debian_payload_package() (
    local payload_output="$1"
    local payload_jobs="$2"
    local payload_backend="$3"
    local packaging_dir="${CIX_ROOT}/${TARGET[debian]}"
    local source_dir="${CIX_ROOT}/${TARGET[source]}"
    local source_git="${CIX_ROOT}/${TARGET[source_git]}"
    local source_date_epoch
    local source_package
    local source_tree
    local upstream_version
    local work_root=

    cix_validate_packaging "${packaging_dir}" "3.0 (quilt)"
    [[ -d "${source_dir}" ]] || cix_die "payload source is missing: ${source_dir}"
    git -C "${source_git}" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
        cix_die "payload source is not a Git worktree: ${source_git}"

    cix_materialize_payload_lfs "${source_dir}" "${source_git}"
    cix_validate_payload "${source_dir}"
    [[ -z "$(git -C "${source_git}" status --porcelain)" ]] ||
        cix_die "payload source must be clean before packaging: ${source_git}"

    read -r source_package _ upstream_version < <(
        cix_debian_metadata "${packaging_dir}"
    )
    work_root="$(mktemp -d "${payload_output}/.${TARGET[name]}.XXXXXXXXXX")"
    trap 'rm -rf -- "${work_root}"' EXIT
    source_tree="${work_root}/${source_package}-${upstream_version}"
    cix_log "Assemble ${TARGET[description]} source package"
    mkdir -p -- "${source_tree}"
    cix_stage_payload "${source_dir}" "${source_tree}"

    source_date_epoch="$(git -C "${source_git}" log -1 --format=%ct)"
    cix_create_orig_tar \
        "${source_package}" "${upstream_version}" "${source_date_epoch}" \
        "${source_tree}" "${work_root}"
    cix_add_debian_metadata "${packaging_dir}" "${source_tree}"
    cix_run_debian_backend \
        "${payload_backend}" "${source_package}" "${source_tree}" \
        "${source_date_epoch}" "${work_root}" "${payload_output}" \
        "${payload_jobs}"
)
