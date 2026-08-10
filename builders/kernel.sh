#!/usr/bin/env bash
# Kernel builders used by cix-build.

cix_prepare_kernel_ccache() {
    cix_require_command ccache
    [[ -d /usr/lib/ccache ]] ||
        cix_die "ccache compiler wrappers are missing: /usr/lib/ccache"

    CCACHE_DIR="${HOME}/.cache/cix-neo-sbuild/ccache"
    CCACHE_UMASK=000
    PATH="/usr/lib/ccache:${PATH}"
    export CCACHE_DIR CCACHE_UMASK PATH
    mkdir -p -- "${CCACHE_DIR}"
    cix_log "Use ccache at ${CCACHE_DIR}"
}

cix_kernel_build() (
    local build_action="$1"
    local build_output="$2"
    local build_jobs="$3"
    local build_dir="${build_output}/build"
    local config_target
    local kernel_commit
    local kernel_patch_dir="${CIX_ROOT}/${TARGET[debian]}/patches"
    local kernel_patch_series="${kernel_patch_dir}/series"
    local kernel_source="${CIX_ROOT}/${TARGET[source]}"
    local patch_count=0
    local patch_entry
    local patch_file
    local worktree_registered=0
    local worktree_root=
    local worktree_source=
    local -a config_targets=(defconfig cix.config cix_docker.config)
    local -a package_args=(
        ARCH=arm64
        "DPKG_FLAGS=--jobs=${build_jobs}"
        LOCALVERSION=-generic
        "KDEB_CHANGELOG_DIST=${CIX_SUITE}"
        KDEB_SOURCENAME=cix-linux
    )

    # Invoked by the EXIT trap below.
    # shellcheck disable=SC2317
    cix_kernel_cleanup() {
        local exit_status=$?

        trap - EXIT
        if ((worktree_registered)); then
            if ! git -C "${kernel_source}" worktree remove --force \
                "${worktree_source}"; then
                cix_log "Failed to remove temporary kernel worktree: ${worktree_source}"
                ((exit_status != 0)) || exit_status=1
            fi
        fi
        if [[ -n "${worktree_root}" && -d "${worktree_root}" ]]; then
            rmdir -- "${worktree_root}" 2>/dev/null || true
        fi
        exit "${exit_status}"
    }

    [[ -f "${kernel_source}/Makefile" ]] ||
        cix_die "kernel source is missing: ${kernel_source}"
    cix_require_command dpkg-buildpackage fakeroot make

    if [[ "${build_action}" == "clean" ]]; then
        cix_clean_artifacts "${build_output}"
        if [[ -d "${build_dir}" ]]; then
            cix_log "Clean kernel build directory ${build_dir}"
            make -C "${kernel_source}" O="${build_dir}" ARCH=arm64 clean
        else
            cix_log "Kernel build directory does not exist: ${build_dir}"
        fi
        return 0
    fi

    cix_require_command git
    [[ -f "${kernel_patch_series}" ]] ||
        cix_die "kernel patch series is missing: ${kernel_patch_series}"
    git -C "${kernel_source}" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
        cix_die "kernel source is not a Git worktree: ${kernel_source}"
    [[ -z "$(git -C "${kernel_source}" status --porcelain)" ]] ||
        cix_die "kernel source must be clean before creating the patched build worktree"

    mkdir -p -- "${build_dir}"
    cix_clean_artifacts "${build_output}"
    worktree_root="$(mktemp -d "${build_output}/.kernel-source.XXXXXXXXXX")"
    worktree_source="${worktree_root}/linux"
    trap cix_kernel_cleanup EXIT

    kernel_commit="$(git -C "${kernel_source}" rev-parse HEAD)"
    cix_log "Create patched kernel worktree at ${kernel_commit}"
    git -C "${kernel_source}" worktree add --quiet --detach \
        "${worktree_source}" "${kernel_commit}"
    worktree_registered=1

    while IFS= read -r patch_entry || [[ -n "${patch_entry}" ]]; do
        patch_entry="${patch_entry%%#*}"
        patch_entry="${patch_entry#"${patch_entry%%[![:space:]]*}"}"
        patch_entry="${patch_entry%"${patch_entry##*[![:space:]]}"}"
        [[ -n "${patch_entry}" ]] || continue
        [[ "${patch_entry}" != *[[:space:]]* ]] ||
            cix_die "kernel patch series options are not supported: ${patch_entry}"

        patch_file="$(realpath -m -- "${kernel_patch_dir}/${patch_entry}")"
        [[ "${patch_file}" == "${kernel_patch_dir}/"* ]] ||
            cix_die "kernel patch escapes patch directory: ${patch_entry}"
        [[ -f "${patch_file}" ]] || cix_die "kernel patch is missing: ${patch_file}"

        cix_log "Apply kernel patch: ${patch_entry}"
        git -C "${worktree_source}" apply --check "${patch_file}"
        git -C "${worktree_source}" apply "${patch_file}"
        ((patch_count += 1))
    done < "${kernel_patch_series}"
    ((patch_count > 0)) || cix_die "kernel patch series is empty: ${kernel_patch_series}"

    for config_target in "${config_targets[@]}"; do
        [[ -f "${worktree_source}/arch/arm64/configs/${config_target}" ]] ||
            cix_die "kernel-owned config is missing: ${config_target}"
    done

    cix_prepare_kernel_ccache
    cix_log "Configure kernel with: ${config_targets[*]}"
    make -C "${worktree_source}" \
        O="${build_dir}" \
        ARCH=arm64 \
        -j"${build_jobs}" \
        "${config_targets[@]}"

    cix_log "Build kernel Debian packages in ${build_output}"
    make -C "${worktree_source}" \
        O="${build_dir}" \
        -j"${build_jobs}" \
        "${package_args[@]}" \
        bindeb-pkg

    cix_log "Kernel package build complete"
)

cix_stable_kernel_build() (
    local build_action="$1"
    local build_output="$2"
    local build_jobs="$3"
    local patch_commit
    local patch_remote="${build_output}/work/.cix-linux-main.git"
    local patch_source="${CIX_ROOT}/${TARGET[patch_source]}"
    local stable_source="${CIX_ROOT}/${TARGET[source]}"
    local upstream_builder="${stable_source}/native/build-kernel-native.sh"
    local work_dir="${build_output}/work"

    [[ -x "${upstream_builder}" ]] ||
        cix_die "stable kernel builder is missing: ${upstream_builder}"
    [[ -d "${patch_source}/.git" || -f "${patch_source}/.git" ]] ||
        cix_die "CIX stable kernel patch source is missing: ${patch_source}"

    if [[ "${build_action}" == "clean" ]]; then
        cix_clean_artifacts "${build_output}"
        if [[ -d "${work_dir}" ]]; then
            cix_log "Remove generated stable kernel work files; preserve tarball cache"
            find "${work_dir}" -mindepth 1 -maxdepth 1 \
                ! -name 'linux-*.tar.xz' -exec rm -rf -- {} +
        fi
        return 0
    fi

    cix_require_command \
        bc bison curl dpkg-buildpackage fakeroot flex gcc git make openssl \
        pahole realpath rsync tar xz
    [[ -z "$(git -C "${stable_source}" status --porcelain)" ]] ||
        cix_die "stable kernel build harness must be clean: ${stable_source}"
    [[ -z "$(git -C "${patch_source}" status --porcelain)" ]] ||
        cix_die "stable kernel patch source must be clean: ${patch_source}"

    cix_prepare_kernel_ccache
    mkdir -p -- "${work_dir}"
    cix_clean_artifacts "${build_output}"
    patch_commit="$(git -C "${patch_source}" rev-parse HEAD)"
    if [[ ! -d "${patch_remote}" ]]; then
        git init --quiet --bare "${patch_remote}"
    fi
    git -C "${patch_remote}" fetch --quiet --force --no-tags \
        "${patch_source}" "${patch_commit}"
    git -C "${patch_remote}" update-ref refs/heads/main "${patch_commit}"

    cix_log "Build stable CIX kernel from ${stable_source}"
    cix_log "Use manifest-managed CIX patches at ${patch_commit}"
    cd "${stable_source}/native" || exit
    BUILD_JOBS="${build_jobs}" \
    KDEB_CHANGELOG_DIST="${CIX_SUITE}" \
    OUTPUT_DIR="${build_output}" \
    PATCH_BRANCH=main \
    PATCH_REMOTE="${patch_remote}" \
    WORK_DIR="${work_dir}" \
        "${upstream_builder}"
)
