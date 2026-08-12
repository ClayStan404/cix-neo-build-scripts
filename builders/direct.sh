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
        *)
            cix_die "unsupported direct build flow: ${TARGET[flow]}"
            ;;
    esac
}
