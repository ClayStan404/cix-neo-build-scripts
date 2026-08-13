#!/usr/bin/env bash
# Build and package Radxa Orion O6 platform firmware on native ARM64.

cix_radxa_o6_validate_edk2_inputs() {
    local edk2_source="$1"
    local dependency
    local -a dependencies=(
        BaseTools/Source/C/BrotliCompress/brotli
        CryptoPkg/Library/MbedTlsLib/mbedtls
        CryptoPkg/Library/OpensslLib/openssl
        MdeModulePkg/Library/BrotliCustomDecompressLib/brotli
        MdeModulePkg/Universal/RegularExpressionDxe/oniguruma
        MdePkg/Library/BaseFdtLib/libfdt
        MdePkg/Library/MipiSysTLib/mipisyst
        RedfishPkg/Library/JsonLib/jansson
        SecurityPkg/DeviceSecurity/SpdmLib/libspdm
        UnitTestFrameworkPkg/Library/CmockaLib/cmocka
        UnitTestFrameworkPkg/Library/GoogleTestLib/googletest
        UnitTestFrameworkPkg/Library/SubhookLib/subhook
    )

    for dependency in "${dependencies[@]}"; do
        git -C "${edk2_source}/${dependency}" rev-parse \
            --is-inside-work-tree >/dev/null 2>&1 ||
            cix_die "EDK2 dependency is not synced; run repo sync: ${dependency}"
    done
}

cix_direct_radxa_o6_firmware_build() (
    local build_action="$1"
    local build_output="$2"
    local build_jobs="$3"
    local firmware_source="${CIX_ROOT}/${TARGET[source]}"
    local uefi_source="${firmware_source}/uefi_release"
    local edk2_source="${uefi_source}/edk2"
    local generated_output="${uefi_source}/output"
    local image_output="${build_output}/images"
    local package_script="${uefi_source}/edk2-non-osi/Platform/CIX/Sky1/PackageTool/build_and_package.sh"
    local package_tool="${uefi_source}/edk2-non-osi/Platform/CIX/Sky1/PackageTool/AARCH64/cix_package_tool"
    local internal_package_script="${firmware_source}/cix_bsp_release/sky1/package_internal_flash_binary.sh"

    if [[ "${build_action}" == "clean" ]]; then
        cix_clean_artifacts "${build_output}"
        if [[ -d "${image_output}" ]]; then
            cix_log "Remove Radxa O6 firmware artifacts"
            find "${image_output}" -mindepth 1 -delete
        fi
        if [[ -d "${uefi_source}/Build" ]]; then
            cix_log "Remove generated EDK2 build files"
            find "${uefi_source}/Build" -mindepth 0 -delete
        fi
        if [[ -d "${generated_output}" ]]; then
            find "${generated_output}" -mindepth 0 -delete
        fi
        if [[ -d "${edk2_source}/BaseTools/Source/C/bin" ]]; then
            make -C "${edk2_source}/BaseTools" clean
        fi
        return 0
    fi

    cix_require_command file find gcc git make python python3
    [[ -f "${edk2_source}/edksetup.sh" ]] ||
        cix_die "EDK2 source is missing: ${edk2_source}"
    [[ -x "${package_script}" ]] ||
        cix_die "Radxa O6 package script is missing: ${package_script}"
    [[ -x "${internal_package_script}" ]] ||
        cix_die "CIX internal package script is missing: ${internal_package_script}"
    [[ -x "${package_tool}" ]] ||
        cix_die "native ARM64 CIX package tool is missing: ${package_tool}"
    [[ "$(LC_ALL=C file -b "${package_tool}")" == *"ARM aarch64"* ]] ||
        cix_die "CIX package tool is not an ARM64 executable: ${package_tool}"
    [[ -f "${uefi_source}/edk2-platforms/Platform/Radxa/Orion/O6/O6.dsc" ]] ||
        cix_die "Radxa O6 EDK2 platform description is missing"
    [[ -f "${uefi_source}/tools/acpica/Makefile" ]] ||
        cix_die "ACPICA source is missing: ${uefi_source}/tools/acpica"
    cix_radxa_o6_validate_edk2_inputs "${edk2_source}"

    cix_prepare_host_ccache
    cix_clean_artifacts "${build_output}"
    if [[ -d "${image_output}" ]]; then
        find "${image_output}" -mindepth 1 -delete
    fi
    mkdir -p -- "${image_output}/ocb"

    cix_log "Build EDK2 host tools with ${build_jobs} jobs"
    make -C "${edk2_source}/BaseTools" \
        -j"${build_jobs}" \
        BUILD_LFLAGS=-no-pie \
        EXTRA_LDFLAGS=-no-pie
    make -C "${uefi_source}/tools/acpica" -j"${build_jobs}"

    cix_log "Build Radxa Orion O6 firmware with ${build_jobs} jobs"
    (
        cd "${uefi_source}" || exit
        NETWORK=open "${package_script}" O6
    )

    cix_log "Generate CIX internal Radxa O6 debug images"
    (
        cd "${uefi_source}" || exit
        SOC_TYPE=sky1 MAKEFLAGS="-j${build_jobs}" \
            "${internal_package_script}"
    )

    for artifact in \
        cix_flash_all.bin \
        cix_flash_ota.bin \
        cix_flash_all_rsa_pr_debug.bin \
        cix_flash_ota_rsa_pr_debug.bin; do
        [[ -s "${generated_output}/${artifact}" ]] ||
            cix_die "Radxa O6 firmware artifact is missing: ${artifact}"
    done

    cp -- "${generated_output}/cix_flash_all.bin" \
        "${image_output}/cix_flash_all_O6.bin"
    cp -- "${generated_output}/cix_flash_ota.bin" \
        "${image_output}/cix_flash_ota_O6.bin"
    cp -- "${generated_output}/cix_flash_all_rsa_pr_debug.bin" \
        "${image_output}/cix_flash_all_O6_pr_debug.bin"
    cp -- "${generated_output}/cix_flash_ota_rsa_pr_debug.bin" \
        "${image_output}/cix_flash_ota_O6_pr_debug.bin"
    cp -- "${image_output}"/cix_flash_all*.bin "${image_output}/ocb/"

    if [[ -s "${generated_output}/bootloader1_ocb_pr.img" ]]; then
        cp -- "${generated_output}/bootloader1_ocb_pr.img" \
            "${image_output}/ocb/bootloader1_pr.img"
    fi
    if [[ -s "${generated_output}/LinuxLoader.efi.cap" ]]; then
        cp -- "${generated_output}/LinuxLoader.efi.cap" "${build_output}/"
    fi

    cix_log "Radxa Orion O6 firmware build complete"
)
