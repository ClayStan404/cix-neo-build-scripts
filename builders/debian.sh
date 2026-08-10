#!/usr/bin/env bash
# Generic Debian source-package builder used by cix-build.

CIX_ARTIFACTS_DIR=
CIX_PACKAGE_WORK_ROOT=
CIX_SBUILD_CCACHE=
CIX_SBUILD_CHROOT_FILE=
CIX_SBUILD_CONFIG_FILE=
CIX_SBUILD_TMP_TEMPLATE=
CIX_SOURCE_PACKAGE=
CIX_DEBIAN_VERSION=
CIX_UPSTREAM_VERSION=

cix_package_cleanup() {
    local exit_status=$?

    trap - EXIT
    if [[ -n "${CIX_PACKAGE_WORK_ROOT}" && -d "${CIX_PACKAGE_WORK_ROOT}" ]]; then
        rm -rf -- "${CIX_PACKAGE_WORK_ROOT}"
    fi
    exit "${exit_status}"
}

cix_sbuild_init() {
    CIX_ARTIFACTS_DIR="$(realpath -m -- "${CIX_OUTPUT_DIR}/artifacts")"
    CIX_SBUILD_CONFIG_FILE="${CIX_SCRIPTS_DIR}/sbuild/config.pl"
    CIX_SBUILD_CHROOT_FILE="${CIX_SBUILD_CHROOT:-${HOME}/.cache/sbuild/${CIX_DISTRIBUTION}-arm64-sbuild.tar.zst}"
    CIX_SBUILD_CHROOT_FILE="$(realpath -m -- "${CIX_SBUILD_CHROOT_FILE}")"
    CIX_SBUILD_CCACHE="${CIX_SBUILD_CCACHE_DIR:-${XDG_CACHE_HOME:-${HOME}/.cache}/cix-neo-sbuild/ccache}"
    CIX_SBUILD_CCACHE="$(realpath -m -- "${CIX_SBUILD_CCACHE}")"
    CIX_SBUILD_TMP_TEMPLATE="${CIX_SBUILD_TMPDIR_TEMPLATE:-/var/tmp/cix-neo-sbuild/tmp.sbuild.XXXXXXXXXX}"
}

cix_sbuild_validate_environment() {
    [[ -f "${CIX_SBUILD_CONFIG_FILE}" ]] ||
        cix_die "sbuild configuration is missing: ${CIX_SBUILD_CONFIG_FILE}"
    [[ -s "${CIX_SBUILD_CHROOT_FILE}" ]] ||
        cix_die "sbuild chroot is missing; run ${CIX_SCRIPTS_DIR}/setup-sbuild: ${CIX_SBUILD_CHROOT_FILE}"
    [[ -d "${CIX_SBUILD_CCACHE}" ]] ||
        cix_die "sbuild ccache is missing; run ${CIX_SCRIPTS_DIR}/setup-sbuild: ${CIX_SBUILD_CCACHE}"
    [[ -d "$(dirname -- "${CIX_SBUILD_TMP_TEMPLATE}")" ]] ||
        cix_die "sbuild temporary directory is missing; run ${CIX_SCRIPTS_DIR}/setup-sbuild"
}

cix_validate_packaging() {
    local packaging_dir="$1"
    local expected_format="$2"
    local source_format

    [[ -f "${packaging_dir}/control" && -f "${packaging_dir}/changelog" ]] ||
        cix_die "${CIX_TARGET_DESCRIPTION} Debian metadata is missing: ${packaging_dir}"
    [[ -f "${packaging_dir}/source/format" ]] ||
        cix_die "Debian source format is missing: ${packaging_dir}/source/format"
    source_format="$(<"${packaging_dir}/source/format")"
    [[ "${source_format}" == "${expected_format}" ]] ||
        cix_die "${CIX_TARGET_DESCRIPTION} must use source format ${expected_format}; found ${source_format}"
}

cix_read_debian_metadata() {
    local packaging_dir="$1"

    CIX_SOURCE_PACKAGE="$(dpkg-parsechangelog -l"${packaging_dir}/changelog" -S Source)"
    CIX_DEBIAN_VERSION="$(dpkg-parsechangelog -l"${packaging_dir}/changelog" -S Version)"
    CIX_UPSTREAM_VERSION="${CIX_DEBIAN_VERSION#*:}"
    CIX_UPSTREAM_VERSION="${CIX_UPSTREAM_VERSION%%-*}"
    [[ -n "${CIX_SOURCE_PACKAGE}" && -n "${CIX_UPSTREAM_VERSION}" ]] ||
        cix_die "cannot determine Debian source package name and version"
}

cix_create_orig_tar() {
    local source_date_epoch="$1"
    local source_tree="$2"
    local work_root="$3"
    local orig_tar="${work_root}/${CIX_SOURCE_PACKAGE}_${CIX_UPSTREAM_VERSION}.orig.tar.xz"

    tar --sort=name \
        --mtime="@${source_date_epoch}" \
        --owner=0 --group=0 --numeric-owner \
        -C "${work_root}" \
        -cJf "${orig_tar}" \
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
    local work_root="$1"
    local -a dsc_files

    mapfile -d '' -t dsc_files < <(
        find "${work_root}" -maxdepth 1 -type f \
            -name "${CIX_SOURCE_PACKAGE}_*.dsc" -print0
    )
    ((${#dsc_files[@]} == 1)) ||
        cix_die "expected one ${CIX_SOURCE_PACKAGE} dsc; found ${#dsc_files[@]}"
    printf '%s\n' "${dsc_files[0]}"
}

cix_run_sbuild() {
    local dsc_file="$1"
    local source_date_epoch="$2"

    export SOURCE_DATE_EPOCH="${source_date_epoch}"
    export CIX_SBUILD_CHROOT="${CIX_SBUILD_CHROOT_FILE}"
    export CIX_SBUILD_DISTRIBUTION="${CIX_DISTRIBUTION}"
    export CIX_SBUILD_CCACHE_DIR="${CIX_SBUILD_CCACHE}"
    export CIX_SBUILD_OUTPUT_DIR="${CIX_ARTIFACTS_DIR}"
    export CIX_SBUILD_TMPDIR_TEMPLATE="${CIX_SBUILD_TMP_TEMPLATE}"
    cix_set_deb_parallel_jobs "${CIX_JOBS}"
    export SBUILD_CONFIG="${CIX_SBUILD_CONFIG_FILE}"

    cix_log "Build ${CIX_TARGET_DESCRIPTION} with sbuild"
    sbuild \
        --chroot-mode=unshare \
        --dist="${CIX_DISTRIBUTION}" \
        --arch=arm64 \
        --build-dir="${CIX_ARTIFACTS_DIR}" \
        "${dsc_file}"
}

cix_validate_dkms_source() {
    local source_dir="$1"
    local dkms_name
    local dkms_version

    [[ -f "${source_dir}/dkms.conf" ]] ||
        cix_die "DKMS metadata is missing: ${source_dir}/dkms.conf"
    dkms_name="$(sed -n 's/^PACKAGE_NAME="\([^"]*\)"$/\1/p' "${source_dir}/dkms.conf" | head -n1)"
    dkms_version="$(sed -n 's/^PACKAGE_VERSION="\([^"]*\)"$/\1/p' "${source_dir}/dkms.conf" | head -n1)"
    [[ -n "${dkms_name}" && -n "${dkms_version}" ]] ||
        cix_die "cannot determine PACKAGE_NAME/PACKAGE_VERSION from dkms.conf"
    [[ "${CIX_SOURCE_PACKAGE}" == "${dkms_name}" ]] ||
        cix_die "Debian source name ${CIX_SOURCE_PACKAGE} does not match DKMS name ${dkms_name}"
    [[ "${CIX_UPSTREAM_VERSION}" == "${dkms_version}" ]] ||
        cix_die "Debian version ${CIX_UPSTREAM_VERSION} does not match DKMS version ${dkms_version}"
}

cix_sbuild_quilt_package() {
    local packaging_dir="$1"
    local source_dir="${CIX_WORKSPACE_ROOT}/${CIX_TARGET_SOURCE}"
    local source_git="${CIX_WORKSPACE_ROOT}/${CIX_TARGET_SOURCE_GIT}"
    local dsc_file
    local source_date_epoch
    local source_tree

    cix_validate_packaging "${packaging_dir}" "3.0 (quilt)"
    [[ -d "${source_dir}" ]] || cix_die "source directory is missing: ${source_dir}"
    git -C "${source_git}" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
        cix_die "source is not a Git worktree: ${source_git}"
    cix_read_debian_metadata "${packaging_dir}"
    case "${CIX_TARGET_VALIDATE}" in
        "") ;;
        dkms) cix_validate_dkms_source "${source_dir}" ;;
        *) cix_die "unsupported source validation: ${CIX_TARGET_VALIDATE}" ;;
    esac

    mkdir -p -- "${CIX_ARTIFACTS_DIR}" "${CIX_OUTPUT_DIR}"
    CIX_PACKAGE_WORK_ROOT="$(mktemp -d "${CIX_OUTPUT_DIR}/.${CIX_TARGET}.XXXXXXXXXX")"
    trap cix_package_cleanup EXIT
    source_tree="${CIX_PACKAGE_WORK_ROOT}/${CIX_SOURCE_PACKAGE}-${CIX_UPSTREAM_VERSION}"
    cix_log "Assemble ${CIX_TARGET_DESCRIPTION} source package"
    mkdir -p -- "${source_tree}"
    rsync -a --exclude=.git --exclude=/debian/ "${source_dir}/" "${source_tree}/"

    source_date_epoch="$(git -C "${source_git}" log -1 --format=%ct)"
    cix_create_orig_tar "${source_date_epoch}" "${source_tree}" "${CIX_PACKAGE_WORK_ROOT}"
    cix_create_quilt_dsc "${packaging_dir}" "${source_tree}" "${CIX_PACKAGE_WORK_ROOT}"
    dsc_file="$(cix_find_dsc "${CIX_PACKAGE_WORK_ROOT}")"
    cix_run_sbuild "${dsc_file}" "${source_date_epoch}"
}

cix_sbuild_native_package() {
    local packaging_dir="$1"
    local source_git="${CIX_WORKSPACE_ROOT}/${CIX_TARGET_SOURCE_GIT}"
    local dsc_file
    local source_date_epoch
    local source_tree
    local tree_version

    cix_validate_packaging "${packaging_dir}" "3.0 (native)"
    git -C "${source_git}" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
        cix_die "source is not a Git worktree: ${source_git}"
    cix_read_debian_metadata "${packaging_dir}"
    tree_version="${CIX_DEBIAN_VERSION#*:}"

    mkdir -p -- "${CIX_ARTIFACTS_DIR}" "${CIX_OUTPUT_DIR}"
    CIX_PACKAGE_WORK_ROOT="$(mktemp -d "${CIX_OUTPUT_DIR}/.${CIX_TARGET}.XXXXXXXXXX")"
    trap cix_package_cleanup EXIT
    source_tree="${CIX_PACKAGE_WORK_ROOT}/${CIX_SOURCE_PACKAGE}-${tree_version}"
    cix_log "Assemble ${CIX_TARGET_DESCRIPTION} native source package"
    mkdir -p -- "${source_tree}/debian"
    rsync -a "${packaging_dir}/" "${source_tree}/debian/"
    (
        cd "${CIX_PACKAGE_WORK_ROOT}" || exit
        dpkg-source -b "$(basename "${source_tree}")"
    )

    dsc_file="$(cix_find_dsc "${CIX_PACKAGE_WORK_ROOT}")"
    source_date_epoch="$(git -C "${source_git}" log -1 --format=%ct)"
    cix_run_sbuild "${dsc_file}" "${source_date_epoch}"
}

cix_sbuild_package() {
    local packaging_dir="${CIX_WORKSPACE_ROOT}/${CIX_TARGET_DEBIAN}"

    cix_sbuild_init
    if [[ "${CIX_ACTION}" == "clean" ]]; then
        cix_clean_files "${CIX_ARTIFACTS_DIR}" "${CIX_TARGET_DESCRIPTION} artifacts"
        return 0
    fi

    cix_require_command dpkg-parsechangelog dpkg-source find git rsync sbuild tar
    cix_sbuild_validate_environment
    if [[ -n "${CIX_TARGET_SOURCE}" ]]; then
        cix_sbuild_quilt_package "${packaging_dir}"
    else
        cix_sbuild_native_package "${packaging_dir}"
    fi
    cix_log "${CIX_TARGET_DESCRIPTION} build complete"
    cix_print_files "${CIX_ARTIFACTS_DIR}"
}
