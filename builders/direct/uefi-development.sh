#!/usr/bin/env bash
# Build one development UEFI platform directly on the native ARM64 host.

# shellcheck source=builders/direct/edk2.sh
source "${CIX_ROOT}/build-scripts/builders/direct/edk2.sh"

cix_uefi_prepare_workspace() {
    local source_root="$1"
    local build_output="$2"
    local work_root="${build_output}/work"

    cix_edk2_prepare_workspace "${source_root}" "${build_output}"

    cix_apply_patch "${work_root}/edk2-platforms" \
        "${CIX_ROOT}/build-scripts/patches/uefi-development/0001-Platform-CIX-Sky1-use-CIX-PrePi.patch" \
        ignore-space-change
    cix_apply_patch "${work_root}/edk2-platforms" \
        "${CIX_ROOT}/build-scripts/patches/uefi-development/0002-CixFastbootPkg-fix-LibUfdt-native-build.patch"
}

cix_direct_uefi_development_build() (
    local platform="$1"
    local build_action="$2"
    local build_output="$3"
    local build_jobs="$4"
    local source_root="${CIX_ROOT}/${TARGET[source]}"
    local work_root="${build_output}/work"
    local edk2_source="${work_root}/edk2"
    local platform_source="${work_root}/edk2-platforms"
    local acpica_source="${work_root}/tools/acpica"
    local soc
    local platform_board
    local board_name
    local dsc
    local build_date
    local commit_hash
    local result

    case "${platform}" in
        Sky1-Emu|Sky1-Fpga|Sky1-Merak|\
        Sky1P-Emu|Sky1P-Fpga|Sky1P-Evb|Sky1P-Crb1|Sky1P-Crb2|\
        Star1-Emu|Star1-Fpga|Star1-Merak)
            soc="${platform%%-*}"
            platform_board="${platform#*-}"
            ;;
        *)
            cix_die "unsupported development UEFI platform: ${platform}"
            ;;
    esac

    case "${platform_board}" in
        Emu) board_name=emu ;;
        Fpga) board_name=fpga ;;
        Merak|Evb) board_name=evb ;;
        Crb1) board_name=crb1 ;;
        Crb2) board_name=crb2 ;;
    esac
    dsc="Platform/CIX/${soc}/${platform_board}/${platform_board}.dsc"

    if [[ "${build_action}" == "clean" ]]; then
        cix_clean_artifacts "${build_output}"
        cix_edk2_remove_workspace "${source_root}" "${build_output}"
        return 0
    fi

    cix_require_command awk date find gcc gcc-ar git make objcopy python3
    [[ -f "${source_root}/edk2/edksetup.sh" ]] ||
        cix_die "development EDK2 source is missing: ${source_root}/edk2"
    [[ -f "${source_root}/edk2-platforms/${dsc}" ]] ||
        cix_die "development UEFI platform description is missing: ${dsc}"
    [[ -f "${source_root}/tools/acpica/Makefile" ]] ||
        cix_die "ACPICA source is missing: ${source_root}/tools/acpica"
    cix_validate_edk2_inputs "${source_root}/edk2"

    cix_prepare_host_ccache
    cix_clean_artifacts "${build_output}"
    cix_uefi_prepare_workspace "${source_root}" "${build_output}"
    cix_validate_edk2_inputs "${edk2_source}"

    cix_edk2_build_host_tools \
        "${edk2_source}" "${build_jobs}" \
        "${build_output}/edk2-host-tools.log"
    cix_log "Build ACPICA host tools with ${build_jobs} jobs"
    if ! make -s -C "${acpica_source}" -j"${build_jobs}" \
        >"${build_output}/acpica-host-tools.log" 2>&1; then
        tail -n 200 "${build_output}/acpica-host-tools.log" >&2
        cix_die \
            "ACPICA host tools failed; full log: ${build_output}/acpica-host-tools.log"
    fi

    commit_hash="$(git -C "${platform_source}" rev-parse --short=12 HEAD)"
    build_date="$(date +%VM%y%m%dN)"

    export WORKSPACE="${work_root}"
    export PACKAGES_PATH="${edk2_source}:${platform_source}"
    export IASL_PREFIX="${acpica_source}/generate/unix/bin/"
    export GCC5_AARCH64_PREFIX=""
    export PYTHON_COMMAND=python3

    cix_log "Build ${soc} ${platform_board} RELEASE UEFI with ${build_jobs} jobs"
    (
        cd "${work_root}" || exit
        set +u
        # shellcheck disable=SC1091
        source "${edk2_source}/edksetup.sh" BaseTools
        set -u
        build \
            -q \
            -s \
            -n "${build_jobs}" \
            -a AARCH64 \
            -t GCC5 \
            -p "${dsc}" \
            -b RELEASE \
            -D "BOARD_NAME=${board_name}" \
            -D "BUILD_DATE=${build_date}" \
            -D "COMMIT_HASH=${commit_hash}" \
            -D FASTBOOT_LOAD=nvme \
            -D SMP_ENABLE=1 \
            -D ACPI_BOOT_ENABLE=0 \
            -D SYSTEM_LOADER=debian \
            -D VARIABLE_TYPE=SPI \
            -D STANDARD_MM=TRUE \
            -y report.txt \
            -Y COMPILE_INFO
    )

    result="${work_root}/Build/${platform_board}/RELEASE_GCC5/FV/SKY1_BL33_UEFI.fd"
    [[ -s "${result}" ]] ||
        cix_die "${soc} ${platform_board} UEFI artifact is missing: ${result}"
    cp -- "${result}" "${build_output}/SKY1_BL33_UEFI.fd"
    if [[ -s "${work_root}/report.txt" ]]; then
        cp -- "${work_root}/report.txt" "${build_output}/report.txt"
    fi

    cix_edk2_remove_workspace "${source_root}" "${build_output}"
    cix_log "${soc} ${platform_board} development UEFI build complete"
)
