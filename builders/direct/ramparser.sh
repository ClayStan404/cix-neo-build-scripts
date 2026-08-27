#!/usr/bin/env bash
# Build the CIX crash/ramdump parser natively on ARM64.

readonly CIX_RAMPARSER_GDB_VERSION=10.2
readonly CIX_RAMPARSER_GDB_SHA256=b33ad58d687487a821ec8d878daab0f716be60d0936f2e3ac5cf08419ce70350

cix_ramparser_remove_workspace() {
    local source_repository="$1"
    local build_output="$2"
    local worktree="${build_output}/work/source"

    cix_remove_git_worktree "${source_repository}" "${worktree}"
    if [[ -d "${build_output}/work" ]]; then
        find "${build_output}/work" -mindepth 1 -delete
        rmdir "${build_output}/work"
    fi
}

cix_ramparser_gdb_tarball() {
    local cache_root="${CIX_ROOT}/output/.downloads"
    local tarball="${cache_root}/gdb-${CIX_RAMPARSER_GDB_VERSION}.tar.gz"
    local actual_digest

    mkdir -p -- "${cache_root}"
    if [[ ! -s "${tarball}" ]]; then
        cix_log "Download GNU GDB ${CIX_RAMPARSER_GDB_VERSION} source" >&2
        curl -fL --retry 3 \
            -o "${tarball}.partial" \
            "https://ftp.gnu.org/gnu/gdb/gdb-${CIX_RAMPARSER_GDB_VERSION}.tar.gz"
        mv -- "${tarball}.partial" "${tarball}"
    else
        cix_log "Use cached GNU GDB tarball: ${tarball}" >&2
    fi
    actual_digest="$(sha256sum "${tarball}" | awk '{print $1}')"
    [[ "${actual_digest}" == "${CIX_RAMPARSER_GDB_SHA256}" ]] ||
        cix_die "GDB tarball checksum mismatch: ${tarball}"
    printf '%s\n' "${tarball}"
}

cix_direct_ramparser_build() (
    local build_action="$1"
    local build_output="$2"
    local build_jobs="$3"
    local source_repository="${CIX_ROOT}/${TARGET[source]}"
    local worktree="${build_output}/work/source"
    local crash_source="${worktree}/cix_crash"
    local published="${build_output}/ramparser"
    local patch_file="${CIX_ROOT}/build-scripts/patches/ramparser/0001-build-native-arm64-release.patch"
    local rdr_patch_file="${CIX_ROOT}/build-scripts/patches/ramparser/0002-rdr-use-local-kernel-headers.patch"
    local kernel_source="${CIX_ROOT}/${TARGET_SOURCE_OVERLAYS[0]%%=*}"
    local gdb_tarball

    # Invoked by the EXIT trap below.
    # shellcheck disable=SC2317
    cix_ramparser_cleanup() {
        local exit_status=$?

        trap - EXIT
        cix_ramparser_remove_workspace "${source_repository}" "${build_output}" ||
            exit_status=1
        exit "${exit_status}"
    }

    mkdir -p -- "${build_output}"
    cix_ramparser_remove_workspace "${source_repository}" "${build_output}"
    cix_clean_artifacts "${build_output}"
    if [[ -d "${published}" ]]; then
        find "${published}" -mindepth 1 -delete
        rmdir "${published}"
    fi
    if [[ "${build_action}" == clean ]]; then
        return 0
    fi

    cix_require_command awk curl file find git make readelf sed sha256sum tar
    cix_preflight_git "${source_repository}"
    cix_preflight_git "${kernel_source}"
    gdb_tarball="$(cix_ramparser_gdb_tarball)"
    trap cix_ramparser_cleanup EXIT
    mkdir -p -- "$(dirname "${worktree}")"
    git -C "${source_repository}" worktree add --detach "${worktree}" HEAD
    cix_apply_patch "${worktree}" "${patch_file}"
    cix_apply_patch "${worktree}" "${rdr_patch_file}"
    install -m 0644 "${gdb_tarball}" \
        "${crash_source}/gdb-${CIX_RAMPARSER_GDB_VERSION}.tar.gz"

    cix_prepare_host_ccache
    cix_log "Build CIX ramparser natively on ARM64 with ${build_jobs} jobs"
    CIX_LINUX_SOURCE="${kernel_source}" \
    CIX_LINUX_REVISION="${TARGET[header_revision]}" \
    make -C "${crash_source}" -j"${build_jobs}" \
        target=ARM64 CIX_NATIVE_HOST=1 all

    for binary in crash rdr ramlog; do
        [[ -x "${crash_source}/release/${binary}" ]] ||
            cix_die "ramparser binary was not generated: ${binary}"
        readelf -h "${crash_source}/release/${binary}" |
            grep -Eq 'Machine:[[:space:]]+AArch64' ||
            cix_die "ramparser binary is not native AArch64: ${binary}"
    done

    mkdir -p -- "${published}"
    cp -a -- "${crash_source}/release/." "${published}/"
    install -m 0644 "${crash_source}/README" "${published}/README"
    install -m 0644 "${crash_source}/COPYING3" "${published}/COPYING3"
    printf '%s\n' \
        "crash: native ARM64" \
        "ramlog: native ARM64" \
        "rdr: legacy blackbox ABI headers ${TARGET[header_revision]}" \
        >"${published}/BUILD-INFO"
    cix_ramparser_remove_workspace "${source_repository}" "${build_output}"
    trap - EXIT
    (
        cd "${build_output}" || exit
        find ramparser -type f -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS
    )
)
