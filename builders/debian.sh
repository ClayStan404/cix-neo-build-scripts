#!/usr/bin/env bash
# Standard Debian source-package builder with selectable execution backends.

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

cix_add_debian_metadata() {
    local packaging_dir="$1"
    local source_tree="$2"

    mkdir -p -- "${source_tree}/debian"
    rsync -a \
        --exclude=/.debhelper/ \
        --exclude=/files \
        --exclude='/*.debhelper.log' \
        --exclude='/*.substvars' \
        "${packaging_dir}/" "${source_tree}/debian/"
}

cix_create_dsc() {
    local source_tree="$1"
    local work_root="$2"

    (
        cd "${work_root}" || exit
        dpkg-source -b "$(basename "${source_tree}")"
    )
}

cix_apply_quilt_patches() {
    local source_tree="$1"
    local patch_name
    local patch_index
    local -a applied_patches=()
    local -a expected_patches=()

    mapfile -t expected_patches < <(
        sed -e 's/[[:space:]].*$//' -e '/^#/d' -e '/^$/d' \
            "${source_tree}/debian/patches/series" 2>/dev/null || true
    )
    ((${#expected_patches[@]} > 0)) || return 0

    (
        cd "${source_tree}" || exit
        dpkg-source --before-build .
    )
    [[ -f "${source_tree}/.pc/applied-patches" ]] ||
        cix_die "quilt patches were not applied: ${TARGET[description]}"
    mapfile -t applied_patches < "${source_tree}/.pc/applied-patches"
    ((${#applied_patches[@]} == ${#expected_patches[@]})) ||
        cix_die "not all quilt patches were applied: ${TARGET[description]}"
    for patch_index in "${!expected_patches[@]}"; do
        patch_name="${expected_patches[patch_index]}"
        [[ "${applied_patches[patch_index]}" == "${patch_name}" ]] ||
            cix_die "unexpected applied quilt patch: ${applied_patches[patch_index]}"
    done
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

cix_collect_internal_dependency_debs() {
    local result_name="$1"
    local -n result="${result_name}"
    local candidate
    local dependency
    local dependency_spec
    local package_name
    local provider_dir
    local -a candidates=()

    result=()

    for dependency_spec in "${TARGET_BUILD_PACKAGES[@]}"; do
        dependency="${dependency_spec%%=*}"
        provider_dir="${CIX_ROOT}/output/${dependency_spec#*=}"
        [[ -d "${provider_dir}" ]] ||
            cix_die "dependency output is missing: ${provider_dir}"
        candidates=()
        while IFS= read -r -d '' candidate; do
            package_name="$(dpkg-deb -f "${candidate}" Package)"
            [[ "${package_name}" == "${dependency}" ]] && candidates+=("${candidate}")
        done < <(
            find "${provider_dir}" -maxdepth 1 -type f -name '*.deb' -print0
        )
        ((${#candidates[@]} == 1)) ||
            cix_die "expected one built ${dependency} package in ${provider_dir}; found ${#candidates[@]}"
        result+=("${candidates[0]}")
    done
}

cix_run_sbuild() {
    local dsc_file="$1"
    local source_date_epoch="$2"
    local build_output="$3"
    local build_jobs="$4"
    local ccache_dir
    local chroot
    local config="${CIX_ROOT}/build-scripts/sbuild/config.pl"
    local validate_chroot="${CIX_ROOT}/build-scripts/sbuild/validate-chroot"
    local tmpdir_root="${CIX_SBUILD_TMPDIR_ROOT:-/var/tmp/cix-neo-sbuild}"
    local dependency_deb
    local -a dependency_debs=()
    local -a extra_package_args=()

    chroot="${CIX_SBUILD_CHROOT:-${HOME}/.cache/sbuild/${CIX_SUITE}-arm64-sbuild.tar.zst}"
    chroot="$(realpath -m -- "${chroot}")"
    ccache_dir="${HOME}/.cache/cix-neo-sbuild/ccache"

    [[ -f "${config}" ]] || cix_die "sbuild configuration is missing: ${config}"
    [[ -x "${validate_chroot}" ]] ||
        cix_die "sbuild chroot validator is missing: ${validate_chroot}"
    [[ -s "${chroot}" ]] ||
        cix_die "sbuild chroot is missing; run build-scripts/setup-sbuild: ${chroot}"
    "${validate_chroot}" "${chroot}" "${CIX_SUITE}" main non-free ||
        cix_die "incompatible sbuild chroot; run build-scripts/setup-sbuild --force"
    [[ -d "${ccache_dir}" ]] ||
        cix_die "sbuild ccache is missing; run build-scripts/setup-sbuild: ${ccache_dir}"
    [[ -d "${tmpdir_root}" ]] ||
        cix_die "sbuild temporary directory is missing; run build-scripts/setup-sbuild"

    cix_collect_internal_dependency_debs dependency_debs
    for dependency_deb in "${dependency_debs[@]}"; do
        extra_package_args+=(--extra-package="${dependency_deb}")
    done

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
            "${extra_package_args[@]}" \
            "${dsc_file}"
}

cix_install_local_internal_dependencies() {
    local candidate
    local package_name
    local package_version
    local -a apt_sources=()
    local -a dependency_debs=()
    local -a install_requests=()

    ((${#TARGET_BUILD_PACKAGES[@]} > 0)) || return 0
    cix_require_command apt-get dpkg-deb sudo
    cix_collect_internal_dependency_debs dependency_debs

    for candidate in "${dependency_debs[@]}"; do
        apt_sources+=(--with-source="${candidate}")
        package_name="$(dpkg-deb -f "${candidate}" Package)"
        package_version="$(dpkg-deb -f "${candidate}" Version)"
        install_requests+=("${package_name}=${package_version}")
    done

    cix_log "Install locally built dependencies for ${TARGET[description]}"
    sudo DEBIAN_FRONTEND=noninteractive \
        apt-get "${apt_sources[@]}" install -y --no-install-recommends \
        "${install_requests[@]}"
}

cix_run_local_dpkg() (
    local source_tree="$1"
    local source_date_epoch="$2"
    local build_output="$3"
    local build_jobs="$4"
    local artifact
    local deb_count=0
    local work_root
    local -a artifacts=()

    work_root="$(dirname "${source_tree}")"
    cix_install_local_internal_dependencies
    cix_prepare_host_ccache
    cix_log "Build ${TARGET[description]} locally with dpkg-buildpackage"
    (
        cd "${source_tree}" || exit
        SOURCE_DATE_EPOCH="${source_date_epoch}" \
            dpkg-buildpackage \
                --build=binary \
                --no-sign \
                --jobs-force="${build_jobs}"
    )

    shopt -s nullglob
    artifacts=(
        "${work_root}"/*.deb
        "${work_root}"/*.ddeb
        "${work_root}"/*.udeb
        "${work_root}"/*.buildinfo
        "${work_root}"/*.changes
    )
    for artifact in "${artifacts[@]}"; do
        case "${artifact}" in
            *.deb|*.ddeb|*.udeb) ((deb_count += 1)) ;;
        esac
    done
    ((deb_count > 0)) ||
        cix_die "local build produced no Debian packages: ${TARGET[description]}"
    mv -f -- "${artifacts[@]}" "${build_output}/"
)

cix_run_debian_backend() {
    local backend="$1"
    local source_package="$2"
    local source_tree="$3"
    local source_date_epoch="$4"
    local work_root="$5"
    local build_output="$6"
    local build_jobs="$7"
    local dsc_file

    case "${backend}" in
        sbuild)
            cix_create_dsc "${source_tree}" "${work_root}"
            dsc_file="$(cix_find_dsc "${source_package}" "${work_root}")"
            cix_run_sbuild \
                "${dsc_file}" "${source_date_epoch}" \
                "${build_output}" "${build_jobs}"
            ;;
        local)
            cix_run_local_dpkg \
                "${source_tree}" "${source_date_epoch}" \
                "${build_output}" "${build_jobs}"
            ;;
        *)
            cix_die "unsupported Debian build backend: ${backend}"
            ;;
    esac
}

cix_validate_dkms_metadata() {
    local packaging_dir="$1"
    local source_package="$2"
    local upstream_version="$3"
    local dkms_file
    local dkms_name
    local dkms_version
    local -a dkms_files=()

    mapfile -d '' -t dkms_files < <(
        find "${packaging_dir}" -maxdepth 1 -type f -name '*.dkms' -print0
    )
    ((${#dkms_files[@]} == 1)) ||
        cix_die "expected one DKMS metadata file in ${packaging_dir}; found ${#dkms_files[@]}"
    dkms_file="${dkms_files[0]}"
    dkms_name="$(sed -n 's/^PACKAGE_NAME="\([^"]*\)"$/\1/p' "${dkms_file}" | head -n1)"
    dkms_version="$(sed -n 's/^PACKAGE_VERSION="\([^"]*\)"$/\1/p' "${dkms_file}" | head -n1)"
    [[ -n "${dkms_name}" && -n "${dkms_version}" ]] ||
        cix_die "cannot determine PACKAGE_NAME/PACKAGE_VERSION from ${dkms_file}"
    [[ "${source_package}" == "${dkms_name}" ]] ||
        cix_die "Debian source name ${source_package} does not match DKMS name ${dkms_name}"
    [[ "${dkms_version}" == "#MODULE_VERSION#" || "${upstream_version}" == "${dkms_version}" ]] ||
        cix_die "Debian version ${upstream_version} does not match DKMS version ${dkms_version}"
}

cix_debian_quilt_package() (
    local build_output="$1"
    local build_jobs="$2"
    local build_backend="$3"
    local packaging_dir="${CIX_ROOT}/${TARGET[debian]}"
    local source_dir="${CIX_ROOT}/${TARGET[source]}"
    local quilt_git="${CIX_ROOT}/${TARGET[source_git]}"
    local source_date_epoch
    local source_package
    local source_tree
    local source_exclude
    local source_overlay
    local source_overlay_dir
    local source_overlay_epoch
    local source_overlay_path
    local source_overlay_target
    local upstream_version
    local work_root=
    local -a source_copy_args=(-a --exclude=.git --exclude=/debian/)

    cix_validate_packaging "${packaging_dir}" "3.0 (quilt)"
    [[ -d "${source_dir}" ]] || cix_die "source directory is missing: ${source_dir}"
    git -C "${quilt_git}" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
        cix_die "source is not a Git worktree: ${quilt_git}"
    read -r source_package _ upstream_version < <(
        cix_debian_metadata "${packaging_dir}"
    )
    case "${TARGET[validate]}" in
        "") ;;
        dkms) cix_validate_dkms_metadata "${packaging_dir}" "${source_package}" "${upstream_version}" ;;
        *) cix_die "unsupported source validation: ${TARGET[validate]}" ;;
    esac

    work_root="$(mktemp -d "${build_output}/.${TARGET[name]}.XXXXXXXXXX")"
    trap 'rm -rf -- "${work_root}"' EXIT
    source_tree="${work_root}/${source_package}-${upstream_version}"
    cix_log "Assemble ${TARGET[description]} source package"
    mkdir -p -- "${source_tree}"
    for source_exclude in "${TARGET_SOURCE_EXCLUDES[@]}"; do
        source_copy_args+=(--exclude="/${source_exclude}")
    done
    rsync "${source_copy_args[@]}" "${source_dir}/" "${source_tree}/"
    for source_overlay in "${TARGET_SOURCE_OVERLAYS[@]}"; do
        source_overlay_path="${source_overlay%%=*}"
        source_overlay_target="${source_overlay#*=}"
        source_overlay_dir="${CIX_ROOT}/${source_overlay_path}"
        git -C "${source_overlay_dir}" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
            cix_die "source overlay is not a Git worktree: ${source_overlay_dir}"
        mkdir -p -- "${source_tree}/${source_overlay_target}"
        rsync -a --exclude=.git --exclude=/debian/ \
            "${source_overlay_dir}/" "${source_tree}/${source_overlay_target}/"
    done

    source_date_epoch="$(git -C "${quilt_git}" log -1 --format=%ct)"
    for source_overlay in "${TARGET_SOURCE_OVERLAYS[@]}"; do
        source_overlay_path="${source_overlay%%=*}"
        source_overlay_epoch="$(
            git -C "${CIX_ROOT}/${source_overlay_path}" log -1 --format=%ct
        )"
        if ((source_overlay_epoch > source_date_epoch)); then
            source_date_epoch="${source_overlay_epoch}"
        fi
    done
    cix_create_orig_tar \
        "${source_package}" "${upstream_version}" "${source_date_epoch}" \
        "${source_tree}" "${work_root}"
    cix_add_debian_metadata "${packaging_dir}" "${source_tree}"
    cix_apply_quilt_patches "${source_tree}"
    cix_run_debian_backend \
        "${build_backend}" "${source_package}" "${source_tree}" \
        "${source_date_epoch}" "${work_root}" "${build_output}" "${build_jobs}"
)

cix_debian_native_package() (
    local build_output="$1"
    local build_jobs="$2"
    local build_backend="$3"
    local packaging_dir="${CIX_ROOT}/${TARGET[debian]}"
    local native_git="${CIX_ROOT}/${TARGET[source_git]}"
    local debian_version
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
    cix_add_debian_metadata "${packaging_dir}" "${source_tree}"

    source_date_epoch="$(git -C "${native_git}" log -1 --format=%ct)"
    cix_run_debian_backend \
        "${build_backend}" "${source_package}" "${source_tree}" \
        "${source_date_epoch}" "${work_root}" "${build_output}" "${build_jobs}"
)

cix_debian_build() {
    local build_action="$1"
    local build_output="$2"
    local build_jobs="$3"
    local build_backend="$4"

    if [[ "${build_action}" == "clean" ]]; then
        cix_clean_artifacts "${build_output}"
        return 0
    fi

    cix_require_command dpkg-parsechangelog dpkg-source find git grep realpath rsync sed tar
    case "${build_backend}" in
        sbuild) cix_require_command dpkg-source sbuild ;;
        local) cix_require_command dpkg-buildpackage fakeroot ;;
        *) cix_die "unsupported Debian build backend: ${build_backend}" ;;
    esac
    mkdir -p -- "${build_output}"
    cix_clean_artifacts "${build_output}"
    case "${TARGET[flow]}" in
        quilt)
            cix_debian_quilt_package \
                "${build_output}" "${build_jobs}" "${build_backend}"
            ;;
        native)
            cix_debian_native_package \
                "${build_output}" "${build_jobs}" "${build_backend}"
            ;;
        payload)
            # shellcheck source=builders/debian/payload.sh
            source "${CIX_ROOT}/build-scripts/builders/debian/payload.sh"
            cix_debian_payload_package \
                "${build_output}" "${build_jobs}" "${build_backend}"
            ;;
        *)
            cix_die "unsupported Debian source flow: ${TARGET[flow]}"
            ;;
    esac
    cix_log "${TARGET[description]} build complete"
}
