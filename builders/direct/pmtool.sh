#!/usr/bin/env bash
# Validate and publish the manifest-pinned ARM64 CSU PM inspection tool.

cix_direct_pmtool_build() {
    local requested_action="$1"
    local target_output="$2"
    local source_tool="${CIX_ROOT}/${TARGET[source]}/device/misc/usr/share/cix/bin/pmtool"
    local output_tool="${target_output}/pmtool"
    local expected_sha256="4e49c2050759766716af7760de1daaf79ab7074dd56e907dea221000b96f8c71"
    local actual_sha256

    if [[ "${requested_action}" == "clean" ]]; then
        cix_clean_artifacts "${target_output}"
        return 0
    fi

    cix_require_command file sha256sum
    [[ -x "${source_tool}" ]] ||
        cix_die "manifest-pinned pmtool is missing or not executable: ${source_tool}"
    [[ "$(LC_ALL=C file -b "${source_tool}")" == *"ARM aarch64"* ]] ||
        cix_die "pmtool is not an ARM64 executable: ${source_tool}"
    actual_sha256="$(sha256sum "${source_tool}")"
    actual_sha256="${actual_sha256%% *}"
    [[ "${actual_sha256}" == "${expected_sha256}" ]] ||
        cix_die "pmtool checksum does not match its pinned source revision"

    cix_clean_artifacts "${target_output}"
    mkdir -p -- "${target_output}"
    cp --preserve=mode -- "${source_tool}" "${output_tool}"
    cix_log "Published pmtool at ${output_tool}"
}
