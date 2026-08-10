#!/usr/bin/env bash
# Generic Debian source-package builder used by cix-build.

cix_validate_packaging() {
    local packaging_dir="$1"
    local expected_format="$2"
    local source_format

    [[ -f "${packaging_dir}/control" && -f "${packaging_dir}/changelog" ]] ||
        cix_die "${TARGET[description]} Debian metadata is missing: ${packaging_dir}"
    [[ -f "${packaging_dir}/source/format" ]] ||
        cix_die "Debian source format is missing: ${packaging_dir}/source/format"
    source_format="$(<"${packaging_dir}/source/format")"
    [[ "${source_format}" == "${expected_format}" ]] ||
        cix_die "${TARGET[description]} must use source format ${expected_format}; found ${source_format}"
}

cix_debian_metadata() {
    local packaging_dir="$1"
    local debian_version
    local source_package
    local upstream_version

    source_package="$(dpkg-parsechangelog -l"${packaging_dir}/changelog" -S Source)"
    debian_version="$(dpkg-parsechangelog -l"${packaging_dir}/changelog" -S Version)"
    upstream_version="${debian_version#*:}"
    upstream_version="${upstream_version%%-*}"
    [[ -n "${source_package}" && -n "${upstream_version}" ]] ||
        cix_die "cannot determine Debian source package name and version"
    printf '%s %s %s\n' "${source_package}" "${debian_version}" "${upstream_version}"
}

cix_create_orig_tar() {
    local source_package="$1"
    local upstream_version="$2"
    local source_date_epoch="$3"
    local source_tree="$4"
    local work_root="$5"

    tar --sort=name \
        --mtime="@${source_date_epoch}" \
        --owner=0 --group=0 --numeric-owner \
        -C "${work_root}" \
        -cJf "${work_root}/${source_package}_${upstream_version}.orig.tar.xz" \
        "$(basename "${source_tree}")"
}

cix_create_quilt_dsc() {
    local packaging_dir="$1"
    local source_tree="$2"
    local work_root="$3"

    mkdir -p -- "${source_tree}/debian"
    rsync -a "${packaging_dir}/" "${source_tree}/debian/"
    (
        cd "${work_root}" || exit
        dpkg-source -b "$(basename "${source_tree}")"
    )
}

cix_find_dsc() {
    local source_package="$1"
    local work_root="$2"
    local -a dsc_files

    mapfile -d '' -t dsc_files < <(
        find "${work_root}" -maxdepth 1 -type f \
            -name "${source_package}_*.dsc" -print0
    )
    ((${#dsc_files[@]} == 1)) ||
        cix_die "expected one ${source_package} dsc; found ${#dsc_files[@]}"
    printf '%s\n' "${dsc_files[0]}"
}

cix_run_sbuild() {
    local dsc_file="$1"
    local source_date_epoch="$2"
    local build_output="$3"
    local build_jobs="$4"
    local ccache_dir
    local chroot
    local config="${CIX_ROOT}/build-scripts/sbuild/config.pl"
    local tmpdir_root="${CIX_SBUILD_TMPDIR_ROOT:-/var/tmp/cix-neo-sbuild}"

    chroot="${CIX_SBUILD_CHROOT:-${HOME}/.cache/sbuild/${CIX_SUITE}-arm64-sbuild.tar.zst}"
    chroot="$(realpath -m -- "${chroot}")"
    ccache_dir="${HOME}/.cache/cix-neo-sbuild/ccache"

    [[ -f "${config}" ]] || cix_die "sbuild configuration is missing: ${config}"
    [[ -s "${chroot}" ]] ||
        cix_die "sbuild chroot is missing; run build-scripts/setup-sbuild: ${chroot}"
    [[ -d "${ccache_dir}" ]] ||
        cix_die "sbuild ccache is missing; run build-scripts/setup-sbuild: ${ccache_dir}"
    [[ -d "${tmpdir_root}" ]] ||
        cix_die "sbuild temporary directory is missing; run build-scripts/setup-sbuild"

    cix_log "Build ${TARGET[description]} with sbuild"
    SOURCE_DATE_EPOCH="${source_date_epoch}" \
    CIX_SBUILD_TMPDIR_ROOT="${tmpdir_root}" \
    SBUILD_CONFIG="${config}" \
        sbuild \
            --chroot-mode=unshare \
            --chroot="${chroot}" \
            --dist="${CIX_SUITE}" \
            --arch=arm64 \
            --jobs="${build_jobs}" \
            --build-dir="${build_output}" \
            "${dsc_file}"
}

cix_validate_dkms_source() {
    local source_dir="$1"
    local source_package="$2"
    local upstream_version="$3"
    local dkms_name
    local dkms_version

    [[ -f "${source_dir}/dkms.conf" ]] ||
        cix_die "DKMS metadata is missing: ${source_dir}/dkms.conf"
    dkms_name="$(sed -n 's/^PACKAGE_NAME="\([^"]*\)"$/\1/p' "${source_dir}/dkms.conf" | head -n1)"
    dkms_version="$(sed -n 's/^PACKAGE_VERSION="\([^"]*\)"$/\1/p' "${source_dir}/dkms.conf" | head -n1)"
    [[ -n "${dkms_name}" && -n "${dkms_version}" ]] ||
        cix_die "cannot determine PACKAGE_NAME/PACKAGE_VERSION from dkms.conf"
    [[ "${source_package}" == "${dkms_name}" ]] ||
        cix_die "Debian source name ${source_package} does not match DKMS name ${dkms_name}"
    [[ "${upstream_version}" == "${dkms_version}" ]] ||
        cix_die "Debian version ${upstream_version} does not match DKMS version ${dkms_version}"
}

cix_sbuild_quilt_package() (
    local build_output="$1"
    local build_jobs="$2"
    local packaging_dir="${CIX_ROOT}/${TARGET[debian]}"
    local source_dir="${CIX_ROOT}/${TARGET[source]}"
    local quilt_git="${CIX_ROOT}/${TARGET[source_git]}"
    local dsc_file
    local source_date_epoch
    local source_package
    local source_tree
    local upstream_version
    local work_root=

    cix_validate_packaging "${packaging_dir}" "3.0 (quilt)"
    [[ -d "${source_dir}" ]] || cix_die "source directory is missing: ${source_dir}"
    git -C "${quilt_git}" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
        cix_die "source is not a Git worktree: ${quilt_git}"
    read -r source_package _ upstream_version < <(
        cix_debian_metadata "${packaging_dir}"
    )
    case "${TARGET[validate]}" in
        "") ;;
        dkms) cix_validate_dkms_source "${source_dir}" "${source_package}" "${upstream_version}" ;;
        *) cix_die "unsupported source validation: ${TARGET[validate]}" ;;
    esac

    work_root="$(mktemp -d "${build_output}/.${TARGET[name]}.XXXXXXXXXX")"
    trap 'rm -rf -- "${work_root}"' EXIT
    source_tree="${work_root}/${source_package}-${upstream_version}"
    cix_log "Assemble ${TARGET[description]} source package"
    mkdir -p -- "${source_tree}"
    rsync -a --exclude=.git --exclude=/debian/ "${source_dir}/" "${source_tree}/"

    source_date_epoch="$(git -C "${quilt_git}" log -1 --format=%ct)"
    cix_create_orig_tar \
        "${source_package}" "${upstream_version}" "${source_date_epoch}" \
        "${source_tree}" "${work_root}"
    cix_create_quilt_dsc "${packaging_dir}" "${source_tree}" "${work_root}"
    dsc_file="$(cix_find_dsc "${source_package}" "${work_root}")"
    cix_run_sbuild "${dsc_file}" "${source_date_epoch}" "${build_output}" "${build_jobs}"
)

cix_sbuild_native_package() (
    local build_output="$1"
    local build_jobs="$2"
    local packaging_dir="${CIX_ROOT}/${TARGET[debian]}"
    local native_git="${CIX_ROOT}/${TARGET[source_git]}"
    local debian_version
    local dsc_file
    local source_date_epoch
    local source_package
    local source_tree
    local tree_version
    local work_root=

    cix_validate_packaging "${packaging_dir}" "3.0 (native)"
    git -C "${native_git}" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
        cix_die "source is not a Git worktree: ${native_git}"
    read -r source_package debian_version _ < <(
        cix_debian_metadata "${packaging_dir}"
    )
    tree_version="${debian_version#*:}"

    work_root="$(mktemp -d "${build_output}/.${TARGET[name]}.XXXXXXXXXX")"
    trap 'rm -rf -- "${work_root}"' EXIT
    source_tree="${work_root}/${source_package}-${tree_version}"
    cix_log "Assemble ${TARGET[description]} native source package"
    mkdir -p -- "${source_tree}/debian"
    rsync -a "${packaging_dir}/" "${source_tree}/debian/"
    (
        cd "${work_root}" || exit
        dpkg-source -b "$(basename "${source_tree}")"
    )

    dsc_file="$(cix_find_dsc "${source_package}" "${work_root}")"
    source_date_epoch="$(git -C "${native_git}" log -1 --format=%ct)"
    cix_run_sbuild "${dsc_file}" "${source_date_epoch}" "${build_output}" "${build_jobs}"
)

cix_sbuild_package() {
    local build_action="$1"
    local build_output="$2"
    local build_jobs="$3"

    if [[ "${build_action}" == "clean" ]]; then
        cix_clean_artifacts "${build_output}"
        return 0
    fi

    cix_require_command dpkg-parsechangelog dpkg-source find git rsync sbuild tar
    mkdir -p -- "${build_output}"
    cix_clean_artifacts "${build_output}"
    if [[ -n "${TARGET[source]}" ]]; then
        cix_sbuild_quilt_package "${build_output}" "${build_jobs}"
    else
        cix_sbuild_native_package "${build_output}" "${build_jobs}"
    fi
    cix_log "${TARGET[description]} build complete"
}
