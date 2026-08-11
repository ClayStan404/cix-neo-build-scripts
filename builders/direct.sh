#!/usr/bin/env bash
# Dispatch build flows that run directly on the native host.

cix_direct_build() {
    local build_action="$1"
    local build_output="$2"
    local build_jobs="$3"

    case "${TARGET[flow]}" in
        kernel-worktree|kernel-stable-tarball)
            # shellcheck source=builders/direct/kernel.sh
            source "${CIX_ROOT}/build-scripts/builders/direct/kernel.sh"
            cix_direct_kernel_build \
                "${build_action}" "${build_output}" "${build_jobs}"
            ;;
        *)
            cix_die "unsupported direct build flow: ${TARGET[flow]}"
            ;;
    esac
}
