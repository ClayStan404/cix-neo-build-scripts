#!/usr/bin/env bash
# Fast, non-building checks performed before a target or build set starts.

cix_preflight_git() {
    local repository="$1"

    [[ -d "${repository}" ]] || cix_die "source directory is missing: ${repository}"
    git -C "${repository}" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
        cix_die "source is not a Git worktree: ${repository}"
}

cix_preflight_lfs_payload() {
    local source_dir="$1"
    local file_spec
    local source_name
    local candidate

    for file_spec in "${TARGET_FILES[@]}" "${TARGET_REQUIRED_FILES[@]}"; do
        source_name="${file_spec%%=*}"
        candidate="${source_dir}/${source_name}"
        [[ -e "${candidate}" ]] ||
            cix_die "payload input is missing: ${candidate}; run repo sync"
        if [[ -f "${candidate}" ]] && head -n 1 -- "${candidate}" 2>/dev/null |
            grep -qx 'version https://git-lfs.github.com/spec/v1'; then
            cix_die "Git LFS payload is not hydrated: ${candidate}; run git lfs pull in ${CIX_ROOT}/${TARGET[source_git]}"
        fi
    done
}

cix_preflight_sbuild() {
    local chroot
    local config="${CIX_ROOT}/build-scripts/sbuild/config.pl"
    local validate_chroot="${CIX_ROOT}/build-scripts/sbuild/validate-chroot"
    local tmpdir_root="${CIX_SBUILD_TMPDIR_ROOT:-/var/tmp/cix-neo-sbuild}"

    cix_require_command sbuild unshare
    chroot="${CIX_SBUILD_CHROOT:-${HOME}/.cache/sbuild/${CIX_SUITE}-arm64-sbuild.tar.zst}"
    chroot="$(realpath -m -- "${chroot}")"
    [[ -f "${config}" ]] || cix_die "sbuild configuration is missing: ${config}"
    [[ -x "${validate_chroot}" ]] ||
        cix_die "sbuild chroot validator is missing: ${validate_chroot}"
    [[ -s "${chroot}" ]] ||
        cix_die "sbuild chroot is missing; run build-scripts/setup-sbuild: ${chroot}"
    "${validate_chroot}" "${chroot}" "${CIX_SUITE}" main non-free ||
        cix_die "incompatible sbuild chroot; run build-scripts/setup-sbuild --force"
    [[ -d "${HOME}/.cache/cix-neo-sbuild/ccache" ]] ||
        cix_die "sbuild ccache is missing; run build-scripts/setup-sbuild"
    [[ -d "${tmpdir_root}" && -w "${tmpdir_root}" ]] ||
        cix_die "sbuild temporary directory is unavailable: ${tmpdir_root}"
}

cix_append_patch_series() {
    local result_name="$1"
    local series_file="$2"
    local allow_options="${3:-0}"
    local -n result="${result_name}"
    local patch_dir
    local patch_path
    local entry

    patch_dir="$(dirname "${series_file}")"
    [[ -f "${series_file}" ]] || cix_die "patch series is missing: ${series_file}"
    while IFS= read -r entry || [[ -n "${entry}" ]]; do
        entry="${entry%%#*}"
        entry="${entry#"${entry%%[![:space:]]*}"}"
        entry="${entry%"${entry##*[![:space:]]}"}"
        [[ -n "${entry}" ]] || continue
        [[ "${allow_options}" == 1 || "${entry}" != *[[:space:]]* ]] ||
            cix_die "patch series options are not supported: ${entry}"
        entry="${entry%%[[:space:]]*}"
        patch_path="$(realpath -m -- "${patch_dir}/${entry}")"
        [[ "${patch_path}" == "$(realpath -m -- "${patch_dir}")/"* ]] ||
            cix_die "patch escapes its series directory: ${entry}"
        [[ -s "${patch_path}" ]] || cix_die "patch is missing: ${patch_path}"
        result+=("${patch_path}")
    done <"${series_file}"
}

cix_preflight_patch_series_file() {
    local source_repository="$1"
    local series_file="$2"
    local -a patches=()

    cix_append_patch_series patches "${series_file}"
    ((${#patches[@]} > 0)) || cix_die "patch series is empty: ${series_file}"
    cix_validate_patch_series "${source_repository}" "${patches[@]}"
}

cix_preflight_debian_git_overlay() {
    local source_dir="$1"
    local overlay_dir="$2"
    local base_source
    local overlay_source
    local overlay_patch_count
    local -a patches=()

    cix_validate_packaging "${source_dir}/debian" "3.0 (quilt)"
    [[ -f "${overlay_dir}/changelog" ]] ||
        cix_die "Debian Git overlay changelog is missing: ${overlay_dir}/changelog"
    [[ -f "${overlay_dir}/patches/series" ]] ||
        cix_die "Debian Git overlay patch series is missing: ${overlay_dir}/patches/series"
    base_source="$(dpkg-parsechangelog -l"${source_dir}/debian/changelog" -S Source)"
    overlay_source="$(dpkg-parsechangelog -l"${overlay_dir}/changelog" -S Source)"
    [[ "${base_source}" == "${overlay_source}" ]] ||
        cix_die "Debian Git overlay source ${overlay_source} does not match ${base_source}"
    cix_append_patch_series patches "${source_dir}/debian/patches/series" 1
    overlay_patch_count="${#patches[@]}"
    cix_append_patch_series patches "${overlay_dir}/patches/series" 1
    ((${#patches[@]} > overlay_patch_count)) ||
        cix_die "Debian Git overlay patch series is empty: ${overlay_dir}/patches/series"
    cix_validate_patch_series "${source_dir}" "${patches[@]}"
}

cix_preflight_debian() {
    local backend="$1"
    local packaging_dir="${CIX_ROOT}/${TARGET[debian]}"
    local source_dir="${CIX_ROOT}/${TARGET[source]}"
    local source_git="${CIX_ROOT}/${TARGET[source_git]}"
    local source_package
    local upstream_version

    cix_require_command dpkg-parsechangelog dpkg-source find git grep realpath rsync sed tar
    case "${backend}" in
        sbuild) cix_preflight_sbuild ;;
        local) cix_require_command dpkg-buildpackage fakeroot ;;
        *) cix_die "unsupported Debian build backend: ${backend}" ;;
    esac

    case "${TARGET[flow]}" in
        quilt)
            cix_validate_packaging "${packaging_dir}" "3.0 (quilt)"
            [[ -d "${source_dir}" ]] || cix_die "source directory is missing: ${source_dir}"
            cix_preflight_git "${source_git}"
            read -r source_package _ upstream_version < <(
                cix_debian_metadata "${packaging_dir}"
            )
            if [[ "${TARGET[validate]}" == dkms ]]; then
                cix_validate_dkms_metadata \
                    "${packaging_dir}" "${source_package}" "${upstream_version}"
            fi
            ;;
        debian-git)
            [[ -d "${source_dir}/debian" ]] ||
                cix_die "Debian Git packaging is missing: ${source_dir}/debian"
            cix_preflight_git "${source_dir}"
            [[ -z "$(git -C "${source_dir}" status --porcelain)" ]] ||
                cix_die "Debian Git source must be clean before packaging: ${source_dir}"
            cix_preflight_debian_git_overlay "${source_dir}" "${packaging_dir}"
            ;;
        native)
            cix_validate_packaging "${packaging_dir}" "3.0 (native)"
            cix_preflight_git "${source_git}"
            ;;
        payload)
            cix_validate_packaging "${packaging_dir}" "3.0 (quilt)"
            cix_preflight_git "${source_git}"
            [[ -d "${source_dir}" ]] || cix_die "payload source is missing: ${source_dir}"
            cix_preflight_lfs_payload "${source_dir}"
            ;;
        *) cix_die "unsupported Debian source flow: ${TARGET[flow]}" ;;
    esac
}

cix_preflight_direct() {
    local source_root="${CIX_ROOT}/${TARGET[source]}"
    local patch_root="${CIX_ROOT}/build-scripts/patches"

    cix_require_command git make
    case "${TARGET[flow]}" in
        kernel-worktree)
            cix_preflight_git "${source_root}"
            cix_preflight_patch_series_file \
                "${source_root}" "${CIX_ROOT}/${TARGET[debian]}/patches/series"
            for config in defconfig cix.config cix_docker.config; do
                [[ -f "${source_root}/arch/arm64/configs/${config}" ]] ||
                    cix_die "kernel-owned config is missing: ${config}"
            done
            ;;
        kernel-stable-tarball)
            cix_preflight_git "${CIX_ROOT}/${TARGET[patch_source]}"
            ;;
        sof-firmware)
            [[ -d "${source_root}" ]] || cix_die "SOF source root is missing: ${source_root}"
            ;;
        sky1-firmware|sky1-firmware-engineering)
            cix_preflight_git "${source_root}/uefi_release/edk2"
            cix_preflight_git "${source_root}/uefi_release/edk2-platforms"
            cix_preflight_git "${source_root}/uefi_release/edk2-non-osi"
            cix_preflight_git "${source_root}/uefi_release/tools/acpica"
            cix_validate_edk2_inputs "${source_root}/uefi_release/edk2"
            if [[ "${TARGET[board]}" == O6N ]]; then
                cix_validate_patch_series \
                    "${source_root}/uefi_release/edk2-platforms" \
                    "${patch_root}/radxa-o6n/0001-Platform-Radxa-add-Orion-O6N-support.patch"
                cix_validate_patch_series \
                    "${source_root}/uefi_release/edk2-non-osi" \
                    "${patch_root}/radxa-o6n/0002-Platform-CIX-package-Orion-O6N-firmware.patch"
                "${CIX_ROOT}/build-scripts/ci/verify_o6n_patch.py" \
                    "${source_root}/uefi_release" \
                    "${patch_root}/radxa-o6n/0001-Platform-Radxa-add-Orion-O6N-support.patch"
            fi
            if [[ "${TARGET[flow]}" == sky1-firmware-engineering ]]; then
                cix_validate_patch_series \
                    "${source_root}/cix_bsp_release" \
                    "${patch_root}/radxa-pm-tuning/0002-PackageTool-select-internal-flash-variant.patch"
                cix_validate_patch_series \
                    "${source_root}/uefi_release/edk2-platforms" \
                    "${patch_root}/radxa-pm-tuning/0001-Platform-add-selectable-O6-PM-profiles.patch" \
                    "${patch_root}/radxa-memory-tuning/0001-Make-O6-memory-rate-updates-reliable.patch"
            fi
            ;;
        uefi-development)
            cix_preflight_git "${source_root}/edk2"
            cix_preflight_git "${source_root}/edk2-platforms"
            cix_validate_edk2_inputs "${source_root}/edk2"
            cix_validate_patch_series \
                "${source_root}/edk2-platforms" \
                "${patch_root}/uefi-development/0001-Platform-CIX-Sky1-use-CIX-PrePi.patch" \
                "${patch_root}/uefi-development/0002-CixFastbootPkg-fix-LibUfdt-native-build.patch"
            ;;
        uefi-stmm)
            cix_preflight_git "${source_root}/edk2"
            cix_validate_edk2_inputs "${source_root}/edk2"
            ;;
        sky1-tf-a)
            cix_preflight_git "${source_root}/bsp/tf-a"
            cix_validate_patch_series "${source_root}/bsp/tf-a" \
                "${patch_root}/secure-firmware/0001-tfa-use-debian-native-toolchain.patch"
            ;;
        sky1-pbl)
            cix_preflight_git "${source_root}/bsp/cix_tfa"
            cix_validate_patch_series "${source_root}/bsp/cix_tfa" \
                "${patch_root}/secure-firmware/0001-tfa-use-debian-native-toolchain.patch"
            ;;
        sky1-optee)
            cix_preflight_git "${source_root}/bsp/tee"
            cix_validate_patch_series "${source_root}/bsp/tee" \
                "${patch_root}/secure-firmware/0002-optee-match-internal-api-length-types.patch"
            ;;
        sky1-se-firmware)
            cix_preflight_git "${source_root}/bootloader/firmware"
            cix_validate_patch_series "${source_root}/bootloader/firmware" \
                "${patch_root}/radxa-bootloader/0002-se-firmware-support-debian-native-toolchain.patch"
            ;;
        pmtool)
            [[ -d "${source_root}" ]] || cix_die "PM tool source is missing: ${source_root}"
            ;;
        ramparser)
            cix_preflight_git "${source_root}"
            local kernel_source="${CIX_ROOT}/${TARGET_SOURCE_OVERLAYS[0]%%=*}"
            cix_preflight_git "${kernel_source}"
            git -C "${kernel_source}" cat-file -e \
                "${TARGET[header_revision]}^{commit}" ||
                cix_die "ramparser RDR kernel header revision is unavailable: ${TARGET[header_revision]}"
            cix_validate_patch_series "${source_root}" \
                "${patch_root}/ramparser/0001-build-native-arm64-release.patch" \
                "${patch_root}/ramparser/0002-rdr-use-local-kernel-headers.patch"
            ;;
        cix-test-tools)
            cix_preflight_git "${source_root}"
            cix_validate_patch_series "${source_root}" \
                "${patch_root}/cix-test-tools/0001-uart-fix-status-and-device-copy.patch"
            ;;
        ltp-testsuite)
            cix_preflight_git "${source_root}"
            cix_validate_patch_series "${source_root}" \
                "${patch_root}/ltp/0001-support-debian-13-headers.patch"
            ;;
        *) cix_die "unsupported direct build flow: ${TARGET[flow]}" ;;
    esac
}

cix_preflight_target() {
    local backend="$1"

    case "${TARGET[builder]}" in
        direct) cix_preflight_direct ;;
        debian) cix_preflight_debian "${backend}" ;;
        *) cix_die "unsupported build engine: ${TARGET[builder]}" ;;
    esac
}
