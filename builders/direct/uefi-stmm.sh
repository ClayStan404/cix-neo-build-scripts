#!/usr/bin/env bash
# Build the Sky1 Standalone MM firmware directly on the native ARM64 host.

# shellcheck source=builders/direct/edk2.sh
source "${CIX_ROOT}/build-scripts/builders/direct/edk2.sh"

cix_direct_uefi_stmm_build() (
    local build_action="$1"
    local build_output="$2"
    local build_jobs="$3"
    local source_root="${CIX_ROOT}/${TARGET[source]}"
    local work_root="${build_output}/work"
    local edk2_source="${work_root}/edk2"
    local platform_source="${work_root}/edk2-platforms"
    local dsc="Platform/CIX/Sky1/StandaloneMm.dsc"
    local build_date
    local commit_hash
    local result

    if [[ "${build_action}" == "clean" ]]; then
        cix_clean_artifacts "${build_output}"
        cix_edk2_remove_workspace "${source_root}" "${build_output}"
        return 0
    fi

    cix_require_command awk date find gcc gcc-ar git make objcopy python3
    [[ -f "${source_root}/edk2/edksetup.sh" ]] ||
        cix_die "Standalone MM EDK2 source is missing: ${source_root}/edk2"
    [[ -f "${source_root}/edk2-platforms/${dsc}" ]] ||
        cix_die "Standalone MM platform description is missing: ${dsc}"
    cix_validate_edk2_inputs "${source_root}/edk2"

    cix_prepare_host_ccache
    cix_clean_artifacts "${build_output}"
    cix_edk2_prepare_workspace "${source_root}" "${build_output}"
    cix_validate_edk2_inputs "${edk2_source}"
    cix_edk2_build_host_tools \
        "${edk2_source}" "${build_jobs}" \
        "${build_output}/edk2-host-tools.log"

    commit_hash="$(git -C "${platform_source}" rev-parse --short=12 HEAD)"
    build_date="$(date +%VM%y%m%dN)"

    export WORKSPACE="${work_root}"
    export PACKAGES_PATH="${edk2_source}:${platform_source}"
    export GCC5_AARCH64_PREFIX=""
    export PYTHON_COMMAND=python3

    cix_log "Build Sky1 RELEASE Standalone MM with ${build_jobs} jobs"
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
            -D "BOARD_NAME=evb" \
            -D "BUILD_DATE=${build_date}" \
            -D "COMMIT_HASH=${commit_hash}" \
            -y report.txt
    )

    result="${work_root}/Build/PlatformMmStandalone/RELEASE_GCC5/FV/BL32_AP_EFI_STMM.fd"
    [[ -s "${result}" ]] ||
        cix_die "Standalone MM artifact is missing: ${result}"
    cp -- "${result}" "${build_output}/BL32_AP_EFI_STMM.fd"
    if [[ -s "${work_root}/report.txt" ]]; then
        cp -- "${work_root}/report.txt" "${build_output}/report.txt"
    fi

    cix_edk2_remove_workspace "${source_root}" "${build_output}"
    cix_log "Sky1 Standalone MM build complete"
)
