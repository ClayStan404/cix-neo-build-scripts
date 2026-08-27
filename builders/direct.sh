#!/usr/bin/env bash
# Dispatch build flows that run directly on the native host.

cix_direct_build() {
    local requested_action="$1"
    local target_output="$2"
    local target_jobs="$3"

    case "${TARGET[flow]}" in
        kernel-worktree|kernel-stable-tarball)
            # shellcheck source=builders/direct/kernel.sh
            source "${CIX_ROOT}/build-scripts/builders/direct/kernel.sh"
            cix_direct_kernel_build \
                "${requested_action}" "${target_output}" "${target_jobs}"
            ;;
        sof-firmware)
            # shellcheck source=builders/direct/audio-sof.sh
            source "${CIX_ROOT}/build-scripts/builders/direct/audio-sof.sh"
            cix_direct_audio_sof_build \
                "${requested_action}" "${target_output}" "${target_jobs}"
            ;;
        sky1-firmware|sky1-firmware-engineering)
            # shellcheck source=builders/direct/firmware-sky1.sh
            source "${CIX_ROOT}/build-scripts/builders/direct/firmware-sky1.sh"
            cix_direct_sky1_firmware_build \
                "${TARGET[board]}" \
                "${requested_action}" "${target_output}" "${target_jobs}"
            ;;
        uefi-development)
            # shellcheck source=builders/direct/uefi-development.sh
            source "${CIX_ROOT}/build-scripts/builders/direct/uefi-development.sh"
            cix_direct_uefi_development_build \
                "${TARGET[board]}" \
                "${requested_action}" "${target_output}" "${target_jobs}"
            ;;
        uefi-stmm)
            # shellcheck source=builders/direct/uefi-stmm.sh
            source "${CIX_ROOT}/build-scripts/builders/direct/uefi-stmm.sh"
            cix_direct_uefi_stmm_build \
                "${requested_action}" "${target_output}" "${target_jobs}"
            ;;
        sky1-tf-a|sky1-pbl|sky1-optee|sky1-se-firmware)
            # shellcheck source=builders/direct/secure-firmware.sh
            source "${CIX_ROOT}/build-scripts/builders/direct/secure-firmware.sh"
            cix_direct_secure_firmware_build \
                "${requested_action}" "${target_output}" "${target_jobs}"
            ;;
        pmtool)
            # shellcheck source=builders/direct/pmtool.sh
            source "${CIX_ROOT}/build-scripts/builders/direct/pmtool.sh"
            cix_direct_pmtool_build "${requested_action}" "${target_output}"
            ;;
        ramparser)
            # shellcheck source=builders/direct/ramparser.sh
            source "${CIX_ROOT}/build-scripts/builders/direct/ramparser.sh"
            cix_direct_ramparser_build \
                "${requested_action}" "${target_output}" "${target_jobs}"
            ;;
        cix-test-tools|ltp-testsuite)
            # shellcheck source=builders/direct/validation.sh
            source "${CIX_ROOT}/build-scripts/builders/direct/validation.sh"
            cix_direct_validation_build \
                "${requested_action}" "${target_output}" "${target_jobs}"
            ;;
        *)
            # TARGET is a caller-owned associative array intentionally read here.
            # shellcheck disable=SC2031
            cix_die "unsupported direct build flow: ${TARGET[flow]}"
            ;;
    esac
}
