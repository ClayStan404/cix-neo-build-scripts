#!/usr/bin/env bash
# Build reusable native validation tools without installing them on the host.

cix_validation_remove_workspace() {
    local source_repository="$1"
    local build_output="$2"
    local worktree="${build_output}/work/source"

    cix_remove_git_worktree "${source_repository}" "${worktree}"
    if [[ -d "${build_output}/work" ]]; then
        find "${build_output}/work" -mindepth 1 -delete
        rmdir "${build_output}/work"
    fi
}

cix_validation_publish_binary() {
    local binary="$1"
    local destination="$2"

    [[ -x "${binary}" ]] || cix_die "validation binary was not generated: ${binary}"
    readelf -h "${binary}" | grep -Eq 'Machine:[[:space:]]+AArch64' ||
        cix_die "validation binary is not native AArch64: ${binary}"
    install -m 0755 "${binary}" "${destination}"
}

cix_build_cix_test_tools() {
    local worktree="$1"
    local build_output="$2"
    local build_jobs="$3"
    local tool_output="${build_output}/tools"

    cix_prepare_host_ccache
    cix_log "Build selected CIX hardware validation tools"
    make -C "${worktree}/lt7911_tools" -j"${build_jobs}" all
    make -C "${worktree}/cix_fch_tools" -j"${build_jobs}" all
    make -C "${worktree}/cix_eth_test/phytool" -j"${build_jobs}" all

    mkdir -p -- "${tool_output}"
    cix_validation_publish_binary \
        "${worktree}/lt7911_tools/lt7911_download" \
        "${tool_output}/lt7911_download"
    for binary in i3ctransfer spidev_fdx uart_test uart_transceiver; do
        cix_validation_publish_binary \
            "${worktree}/cix_fch_tools/${binary}" "${tool_output}/${binary}"
    done
    cix_validation_publish_binary \
        "${worktree}/cix_eth_test/phytool/phytool" "${tool_output}/phytool"
    ln -s phytool "${tool_output}/mv6tool"
    install -m 0644 "${worktree}/cix_eth_test/phytool/phytool.8" \
        "${tool_output}/phytool.8"
    install -m 0644 "${worktree}/cix_eth_test/phytool/mv6tool.8" \
        "${tool_output}/mv6tool.8"
}

cix_build_ltp_testsuite() {
    local worktree="$1"
    local build_output="$2"
    local build_jobs="$3"
    local staging="${build_output}/work/staging"

    cix_prepare_host_ccache
    cix_log "Configure CIX-pinned Linux Test Project"
    make -C "${worktree}" -j"${build_jobs}" autotools
    (
        cd "${worktree}" || exit
        ./configure --prefix=/opt/ltp
    )
    cix_log "Build Linux Test Project with ${build_jobs} jobs"
    make -C "${worktree}" -j"${build_jobs}" all
    make -C "${worktree}" -j"${build_jobs}" DESTDIR="${staging}" install
    [[ -x "${staging}/opt/ltp/runltp" ]] ||
        cix_die "LTP installation did not produce /opt/ltp/runltp"
    mv -- "${staging}/opt/ltp" "${build_output}/ltp"
}

cix_direct_validation_build() (
    local build_action="$1"
    local build_output="$2"
    local build_jobs="$3"
    local source_repository="${CIX_ROOT}/${TARGET[source]}"
    local worktree="${build_output}/work/source"
    local -a checksum_files=()

    # Invoked by the EXIT trap below.
    # shellcheck disable=SC2317
    cix_validation_cleanup() {
        local exit_status=$?

        trap - EXIT
        cix_validation_remove_workspace "${source_repository}" "${build_output}" ||
            exit_status=1
        exit "${exit_status}"
    }

    mkdir -p -- "${build_output}"
    cix_validation_remove_workspace "${source_repository}" "${build_output}"
    cix_clean_artifacts "${build_output}"
    for directory in tools ltp; do
        if [[ -d "${build_output}/${directory}" ]]; then
            find "${build_output}/${directory}" -mindepth 1 -delete
            rmdir "${build_output}/${directory}"
        fi
    done
    if [[ "${build_action}" == clean ]]; then
        return 0
    fi

    cix_require_command autoreconf file git make readelf sha256sum
    cix_preflight_git "${source_repository}"
    trap cix_validation_cleanup EXIT
    mkdir -p -- "$(dirname "${worktree}")"
    git -C "${source_repository}" worktree add --detach "${worktree}" HEAD
    case "${TARGET[flow]}" in
        cix-test-tools)
            cix_apply_patch "${worktree}" \
                "${CIX_ROOT}/build-scripts/patches/cix-test-tools/0001-uart-fix-status-and-device-copy.patch"
            cix_build_cix_test_tools "${worktree}" "${build_output}" "${build_jobs}"
            ;;
        ltp-testsuite)
            cix_apply_patch "${worktree}" \
                "${CIX_ROOT}/build-scripts/patches/ltp/0001-support-debian-13-headers.patch"
            cix_build_ltp_testsuite "${worktree}" "${build_output}" "${build_jobs}"
            ;;
        *) cix_die "unsupported validation flow: ${TARGET[flow]}" ;;
    esac
    cix_validation_remove_workspace "${source_repository}" "${build_output}"
    trap - EXIT
    (
        cd "${build_output}" || exit
        mapfile -d '' -t checksum_files < <(
            find . -type f ! -name SHA256SUMS -print0 | sort -z
        )
        ((${#checksum_files[@]} > 0)) ||
            cix_die "validation target produced no files"
        sha256sum "${checksum_files[@]}" >SHA256SUMS
    )
)
