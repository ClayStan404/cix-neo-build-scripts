#!/usr/bin/env bash
# Build native Sky1 trusted and security firmware components.

# shellcheck source=builders/direct/bootloader1.sh
source "${CIX_ROOT}/build-scripts/builders/direct/bootloader1.sh"

cix_secure_remove_workspace() {
    local source_repository="$1"
    local worktree="$2"

    cix_remove_git_worktree "${source_repository}" "${worktree}"
    if [[ -d "${worktree}" ]]; then
        find "${worktree}" -mindepth 1 -delete
        rmdir "${worktree}"
    fi
}

cix_secure_remove_build_workspace() {
    local source_repository="$1"
    local build_output="$2"
    local work_root="${build_output}/work"

    cix_secure_remove_workspace \
        "${source_repository}" "${work_root}/source"
    if [[ -d "${work_root}" ]]; then
        find "${work_root}" -mindepth 1 -delete
        rmdir "${work_root}"
    fi
}

cix_secure_prepare_tfa_source() {
    local source_repository="$1"
    local worktree="$2"
    local patch_file="${CIX_ROOT}/build-scripts/patches/secure-firmware/0001-tfa-use-debian-native-toolchain.patch"

    git -C "${source_repository}" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
        cix_die "trusted-firmware source is not synced: ${source_repository}"
    cix_secure_remove_workspace "${source_repository}" "${worktree}"
    mkdir -p -- "$(dirname "${worktree}")"
    git -C "${source_repository}" worktree add --detach "${worktree}" HEAD
    cix_apply_patch "${worktree}" "${patch_file}"
}

cix_secure_build_tfa_component() {
    local component="$1"
    local build_output="$2"
    local build_jobs="$3"
    local source_root="${CIX_ROOT}/${TARGET[source]}"
    local source_repository
    local worktree="${build_output}/work/source"
    local build_root="${build_output}/work/build"
    local firmware_binary
    local firmware_elf
    local published_binary
    local published_elf
    local make_target

    case "${component}" in
        tf-a)
            source_repository="${source_root}/bsp/tf-a"
            make_target=bl31
            firmware_binary="${build_root}/sky1/release/bl31.bin"
            firmware_elf="${build_root}/sky1/release/bl31/bl31.elf"
            published_binary=tf-a.bin
            published_elf=bl31.elf
            ;;
        pbl)
            source_repository="${source_root}/bsp/cix_tfa"
            make_target=bl2
            firmware_binary="${build_root}/sky1/release/bl2.bin"
            firmware_elf="${build_root}/sky1/release/bl2/bl2.elf"
            published_binary=pbl_fw.bin
            published_elf=bl2.elf
            ;;
        *)
            cix_die "unsupported trusted-firmware component: ${component}"
            ;;
    esac

    git -C "${source_root}/bsp/mbedtls" rev-parse \
        --is-inside-work-tree >/dev/null 2>&1 ||
        cix_die "Sky1 mbedTLS source is not synced"
    git -C "${source_root}/security/library" rev-parse \
        --is-inside-work-tree >/dev/null 2>&1 ||
        cix_die "Sky1 security library source is not synced"

    cix_secure_prepare_tfa_source "${source_repository}" "${worktree}"
    cix_prepare_host_ccache
    cix_log "Build Sky1 ${component} with Debian GCC and ${build_jobs} jobs"
    make -C "${worktree}" -j"${build_jobs}" \
        PATH_ROOT="${source_root}" \
        CROSS_COMPILE= \
        CROSS_COMPILE_ELF="$(command -v gcc)" \
        PLAT=sky1 \
        SPD=opteed \
        DEBUG=0 \
        BUILD_BASE="${build_root}" \
        CIX_BOARD=evb \
        SMP=1 \
        MBEDTLS_DIR="${source_root}/bsp/mbedtls" \
        TRUSTED_BOARD_BOOT=1 \
        ENABLE_FEAT_HCX=1 \
        ARM_ROTPK_LOCATION=devel_rsa \
        ROT_KEY=plat/arm/board/common/rotpk/arm_rotprivk_rsa.pem \
        OPENSSL_DIR=/usr \
        TFA_LOAD_TYPE=ddr \
        "${make_target}"

    [[ -s "${firmware_binary}" ]] ||
        cix_die "Sky1 ${component} binary was not generated"
    [[ -s "${firmware_elf}" ]] ||
        cix_die "Sky1 ${component} ELF was not generated"
    install -m 0644 "${firmware_binary}" "${build_output}/${published_binary}"
    install -m 0644 "${firmware_elf}" "${build_output}/${published_elf}"
    cix_secure_remove_build_workspace "${source_repository}" "${build_output}"
    (
        cd "${build_output}" || exit
        sha256sum "${published_binary}" "${published_elf}" >SHA256SUMS
    )
}

cix_secure_build_optee() {
    local build_output="$1"
    local build_jobs="$2"
    local source_repository="${CIX_ROOT}/${TARGET[source]}/bsp/tee"
    local worktree="${build_output}/work/source"
    local optee_output="${build_output}/work/build"
    local patch_file="${CIX_ROOT}/build-scripts/patches/secure-firmware/0002-optee-match-internal-api-length-types.patch"

    git -C "${source_repository}" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
        cix_die "Sky1 OP-TEE source is not synced"
    cix_secure_remove_build_workspace "${source_repository}" "${build_output}"
    mkdir -p -- "$(dirname "${worktree}")"
    git -C "${source_repository}" worktree add --detach "${worktree}" HEAD
    cix_apply_patch "${worktree}" "${patch_file}"

    cix_prepare_host_ccache
    cix_log "Build Sky1 OP-TEE with Debian GCC and ${build_jobs} jobs"
    make -C "${worktree}" -j"${build_jobs}" \
        O="${optee_output}" \
        ARCH=arm \
        PLATFORM=cix \
        PLATFORM_FLAVOR=sky1 \
        CROSS_COMPILE64= \
        CFG_ARM64_core=y \
        CFG_USER_TA_TARGETS=ta_arm64 \
        all

    [[ -s "${optee_output}/core/tee-raw.bin" ]] ||
        cix_die "Sky1 OP-TEE binary was not generated"
    [[ -s "${optee_output}/core/tee.elf" ]] ||
        cix_die "Sky1 OP-TEE ELF was not generated"
    install -m 0644 "${optee_output}/core/tee-raw.bin" \
        "${build_output}/tee.bin"
    install -m 0644 "${optee_output}/core/tee.elf" \
        "${build_output}/tee.elf"
    cix_secure_remove_build_workspace "${source_repository}" "${build_output}"
    (
        cd "${build_output}" || exit
        sha256sum tee.bin tee.elf >SHA256SUMS
    )
}

cix_secure_build_se() {
    local build_output="$1"
    local build_jobs="$2"
    local source_root="${CIX_ROOT}/${TARGET[source]}"
    local work_root="${build_output}/bootloader-work"
    local patch_file="${CIX_ROOT}/build-scripts/patches/radxa-bootloader/0002-se-firmware-support-debian-native-toolchain.patch"
    local component

    for component in ddr firmware library; do
        git -C "${source_root}/bootloader/${component}" rev-parse \
            --is-inside-work-tree >/dev/null 2>&1 ||
            cix_die "Sky1 bootloader source is not synced: ${component}"
    done

    cix_bootloader1_remove_workspace "${source_root}" "${build_output}"
    mkdir -p -- "${work_root}"
    for component in ddr firmware library; do
        git -C "${source_root}/bootloader/${component}" worktree add --detach \
            "${work_root}/${component}" HEAD
    done
    cix_apply_patch "${work_root}/firmware" "${patch_file}"

    cix_log "Build Sky1 RELEASE SE firmware with Debian ARM Embedded GCC"
    cix_bootloader1_build_se \
        "${work_root}/firmware" release \
        "${build_output}/se_fw.bin" "${build_jobs}" ddr
    for component in elf hex disass; do
        [[ -s "${work_root}/firmware/se_fw.${component}" ]] ||
            cix_die "Sky1 SE firmware ${component} artifact was not generated"
        install -m 0644 "${work_root}/firmware/se_fw.${component}" \
            "${build_output}/se_fw.${component}"
    done
    cix_bootloader1_remove_workspace "${source_root}" "${build_output}"
    (
        cd "${build_output}" || exit
        sha256sum se_fw.bin se_fw.elf se_fw.hex se_fw.disass >SHA256SUMS
    )
}

cix_direct_secure_firmware_build() (
    local build_action="$1"
    local build_output="$2"
    local build_jobs="$3"
    local flow="${TARGET[flow]}"
    local source_root="${CIX_ROOT}/${TARGET[source]}"

    mkdir -p -- "${build_output}"
    case "${flow}" in
        sky1-tf-a)
            cix_secure_remove_build_workspace \
                "${source_root}/bsp/tf-a" "${build_output}"
            ;;
        sky1-pbl)
            cix_secure_remove_build_workspace \
                "${source_root}/bsp/cix_tfa" "${build_output}"
            ;;
        sky1-optee)
            cix_secure_remove_build_workspace \
                "${source_root}/bsp/tee" "${build_output}"
            ;;
        sky1-se-firmware)
            cix_bootloader1_remove_workspace "${source_root}" "${build_output}"
            ;;
        *)
            cix_die "unsupported secure-firmware flow: ${flow}"
            ;;
    esac
    cix_clean_artifacts "${build_output}"
    if [[ "${build_action}" == clean ]]; then
        return
    fi

    case "${flow}" in
        sky1-tf-a)
            cix_secure_build_tfa_component tf-a "${build_output}" "${build_jobs}"
            ;;
        sky1-pbl)
            cix_secure_build_tfa_component pbl "${build_output}" "${build_jobs}"
            ;;
        sky1-optee)
            cix_secure_build_optee "${build_output}" "${build_jobs}"
            ;;
        sky1-se-firmware)
            cix_secure_build_se "${build_output}" "${build_jobs}"
            ;;
    esac
)
