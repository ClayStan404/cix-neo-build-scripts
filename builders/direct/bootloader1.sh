#!/usr/bin/env bash
# Build Sky1 SE/DDR firmware and package bootloader1 images on native ARM64.

cix_bootloader1_remove_workspace() {
    local source_root="$1"
    local build_output="$2"
    local work_root="${build_output}/bootloader-work"

    cix_remove_git_worktree \
        "${source_root}/bootloader/ddr" "${work_root}/ddr"
    cix_remove_git_worktree \
        "${source_root}/bootloader/firmware" "${work_root}/firmware"
    cix_remove_git_worktree \
        "${source_root}/bootloader/library" "${work_root}/library"
    cix_remove_git_worktree \
        "${source_root}/bootloader/sw-tools-private" \
        "${work_root}/sw-tools-private"

    if [[ -d "${work_root}" ]]; then
        find "${work_root}" -mindepth 1 -delete
        rmdir "${work_root}"
    fi
}

cix_bootloader1_clean_artifacts() {
    local artifact_root="$1/bootloader1"

    if [[ -d "${artifact_root}" ]]; then
        cix_log "Remove source-built bootloader1 artifacts"
        find "${artifact_root}" -mindepth 1 -delete
        rmdir "${artifact_root}"
    fi
}

cix_bootloader1_build_se() {
    local firmware_worktree="$1"
    local build_mode="$2"
    local destination="$3"
    local build_jobs="$4"

    make -C "${firmware_worktree}" \
        FW_RUN_PLATFORM=evb \
        FW_BUILD_MODE="${build_mode}" \
        SOC_TYPE=sky1 \
        TFA_LOAD_TYPE=qspi \
        clean
    make -C "${firmware_worktree}" -j"${build_jobs}" \
        FW_RUN_PLATFORM=evb \
        FW_BUILD_MODE="${build_mode}" \
        SOC_TYPE=sky1 \
        TFA_LOAD_TYPE=qspi
    [[ -s "${firmware_worktree}/se_fw.bin" ]] ||
        cix_die "Sky1 ${build_mode} SE firmware was not generated"
    install -m 0644 "${firmware_worktree}/se_fw.bin" "${destination}"
}

cix_bootloader1_package_image() {
    local package_root="$1"
    local artifact_root="$2"
    local work_bsp="$3"
    local build_mode="$4"
    local output="${artifact_root}/bootloader1_proto_${build_mode}.img"
    local config="config/cix_bl1_rsa3072_prototype.json"

    (
        cd "${package_root}" || exit
        ./bin/cix_mkimage_rsa -j "${config}" -o "${output}"
        ./bin/cix_mkimage_rsa -j "${config}" -v "${output}"
    )
    [[ -s "${output}" ]] ||
        cix_die "source-built prototype ${build_mode} bootloader1 is missing"

    mkdir -p -- "${work_bsp}/sky1/proto_${build_mode}/Firmwares"
    install -m 0644 "${output}" \
        "${work_bsp}/sky1/proto_${build_mode}/Firmwares/bootloader1.img"
}

cix_bootloader1_build() {
    local source_root="$1"
    local build_output="$2"
    local build_jobs="$3"
    local work_bsp="$4"
    local source_binary="${CIX_ROOT}/sources/cix-binary"
    local source_firmware_binary="${source_root}/bootloader/firmware-binaries"
    local work_root="${build_output}/bootloader-work"
    local artifact_root="${build_output}/bootloader1"
    local package_root="${work_root}/package"
    local patch_root="${CIX_ROOT}/build-scripts/patches/radxa-bootloader"
    local native_mkimage="${work_root}/sw-tools-private/host/cix_mkimage/cix_mkimage_rsa"
    local secure_tool="${source_binary}/host/security/sky1/cix_secure_boot_tool"
    local prototype_keys="${source_binary}/host/security/sky1/lkms/rsa3072_prototype_keys"
    local image_config="${source_firmware_binary}/sky1/common/cix_config/evb"
    local component

    for component in ddr firmware library sw-tools-private; do
        git -C "${source_root}/bootloader/${component}" rev-parse \
            --is-inside-work-tree >/dev/null 2>&1 ||
            cix_die "Sky1 bootloader source is not synced: ${component}"
    done
    [[ -s "${image_config}/cix_bl1_rsa3072_prototype.json" ]] ||
        cix_die "current Sky1 prototype boot configuration is not synced"
    [[ -s "${prototype_keys}/cix_user_privatekey.pem" ]] ||
        cix_die "Sky1 local prototype signing keys are not synced"
    [[ -s "${source_firmware_binary}/sky1/evb/debug/pm_fw/pm_fw.bin" ]] ||
        cix_die "version-matched Sky1 PM firmware payload is not synced"

    cix_bootloader1_remove_workspace "${source_root}" "${build_output}"
    cix_bootloader1_clean_artifacts "${build_output}"
    mkdir -p -- "${work_root}" "${artifact_root}"

    for component in ddr firmware library sw-tools-private; do
        git -C "${source_root}/bootloader/${component}" worktree add --detach \
            "${work_root}/${component}" HEAD
    done

    cix_apply_patch "${work_root}/ddr" \
        "${patch_root}/0001-ddr-bound-training-and-recover-automatic.patch"
    cix_apply_patch "${work_root}/firmware" \
        "${patch_root}/0002-se-firmware-support-debian-native-toolchain.patch"
    cix_apply_patch "${work_root}/sw-tools-private" \
        "${patch_root}/0003-cix-mkimage-use-system-libraries.patch"

    cix_log "Build native ARM64 cix_mkimage with ${build_jobs} jobs"
    make -C "${work_root}/sw-tools-private/host/cix_mkimage" -j"${build_jobs}"
    [[ "$(LC_ALL=C file -b "${native_mkimage}")" == *"ARM aarch64"* ]] ||
        cix_die "source-built cix_mkimage is not an ARM64 executable"

    cix_log "Build Sky1 debug SE/DDR firmware with Debian GCC"
    cix_bootloader1_build_se \
        "${work_root}/firmware" debug \
        "${artifact_root}/se_fw_debug.bin" "${build_jobs}"

    mkdir -p -- "${package_root}/bin" "${package_root}/images"
    cp -a -- "${secure_tool}/." "${package_root}/"
    install -m 0755 "${native_mkimage}" "${package_root}/bin/cix_mkimage_rsa"
    install -m 0644 "${image_config}/cix_bl1_rsa3072_prototype.json" \
        "${package_root}/config/cix_bl1_rsa3072_prototype.json"
    install -m 0644 "${secure_tool}/images/efuse_fw.bin" \
        "${package_root}/images/efuse_fw.bin"

    mkdir -p -- "${package_root}/rsa3072_prototype_keys"
    install -m 0600 "${prototype_keys}/cix_user_privatekey.pem" \
        "${package_root}/rsa3072_prototype_keys/cix_user_privatekey.pem"
    install -m 0644 "${prototype_keys}/cix_user_publickey.pem" \
        "${package_root}/rsa3072_prototype_keys/cix_user_publickey.pem"
    install -m 0600 "${prototype_keys}/cix_privatekey.pem" \
        "${package_root}/rsa3072_prototype_keys/cix_privatekey.pem"
    install -m 0644 "${prototype_keys}/cix_publickey.pem" \
        "${package_root}/rsa3072_prototype_keys/cix_publickey.pem"

    install -m 0644 "${artifact_root}/se_fw_debug.bin" \
        "${package_root}/images/se_fw.bin"
    install -m 0644 \
        "${source_firmware_binary}/sky1/evb/debug/pm_fw/pm_fw.bin" \
        "${package_root}/images/pm_fw.bin"
    install -m 0644 \
        "${source_firmware_binary}/sky1/evb/debug/pbl_fw/pbl_fw.bin" \
        "${package_root}/images/pbl_fw.bin"
    cix_bootloader1_package_image \
        "${package_root}" "${artifact_root}" "${work_bsp}" debug

    (
        cd "${artifact_root}" || exit
        sha256sum bootloader1_*.img se_fw_*.bin >SHA256SUMS
    )
    cix_bootloader1_remove_workspace "${source_root}" "${build_output}"
    cix_log "Built and verified local-prototype Sky1 bootloader1 images"
    cix_log "Keep revision-pinned pr/pr2 bootloader1 images; product signing requires RKMS"
    cix_log "Do not run the available x86-only cix_kms tool on the ARM64 build host"
}
