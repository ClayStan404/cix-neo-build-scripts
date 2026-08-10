#!/usr/bin/env bash
# Kernel builders used by cix-build.

CIX_KERNEL_WORKTREE_ROOT=
CIX_KERNEL_WORKTREE_SOURCE=
CIX_KERNEL_WORKTREE_REGISTERED=0

cix_kernel_cleanup() {
    local exit_status=$?

    trap - EXIT
    if ((CIX_KERNEL_WORKTREE_REGISTERED)); then
        if ! git -C "${CIX_WORKSPACE_ROOT}/sources/linux" worktree remove --force \
            "${CIX_KERNEL_WORKTREE_SOURCE}"; then
            cix_log "Failed to remove temporary kernel worktree: ${CIX_KERNEL_WORKTREE_SOURCE}"
            ((exit_status != 0)) || exit_status=1
        fi
    fi
    if [[ -n "${CIX_KERNEL_WORKTREE_ROOT}" && -d "${CIX_KERNEL_WORKTREE_ROOT}" ]]; then
        rmdir -- "${CIX_KERNEL_WORKTREE_ROOT}" 2>/dev/null || true
    fi
    exit "${exit_status}"
}

cix_kernel_build() {
    local build_dir
    local config_target
    local kernel_commit
    local kernel_patch_dir="${CIX_WORKSPACE_ROOT}/${CIX_TARGET_DEBIAN}/patches"
    local kernel_patch_series="${kernel_patch_dir}/series"
    local kernel_source="${CIX_WORKSPACE_ROOT}/${CIX_TARGET_SOURCE}"
    local patch_count=0
    local patch_entry
    local patch_file
    local -a config_targets
    local -a package_args

    build_dir="$(realpath -m -- "${CIX_OUTPUT_DIR}/build")"
    [[ -f "${kernel_source}/Makefile" ]] ||
        cix_die "kernel source is missing: ${kernel_source}"
    cix_require_command dpkg-buildpackage fakeroot make

    if [[ "${CIX_ACTION}" == "clean" ]]; then
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

    mkdir -p -- "${build_dir}" "${CIX_OUTPUT_DIR}"
    CIX_KERNEL_WORKTREE_ROOT="$(mktemp -d "${CIX_OUTPUT_DIR}/.kernel-source.XXXXXXXXXX")"
    CIX_KERNEL_WORKTREE_SOURCE="${CIX_KERNEL_WORKTREE_ROOT}/linux"
    trap cix_kernel_cleanup EXIT

    kernel_commit="$(git -C "${kernel_source}" rev-parse HEAD)"
    cix_log "Create patched kernel worktree at ${kernel_commit}"
    git -C "${kernel_source}" worktree add --quiet --detach \
        "${CIX_KERNEL_WORKTREE_SOURCE}" "${kernel_commit}"
    CIX_KERNEL_WORKTREE_REGISTERED=1

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
        git -C "${CIX_KERNEL_WORKTREE_SOURCE}" apply --check "${patch_file}"
        git -C "${CIX_KERNEL_WORKTREE_SOURCE}" apply "${patch_file}"
        ((patch_count += 1))
    done < "${kernel_patch_series}"
    ((patch_count > 0)) || cix_die "kernel patch series is empty: ${kernel_patch_series}"

    config_targets=(defconfig cix.config cix_docker.config)
    case "${CIX_BOARD}" in
        cloudbook|emu|fpga)
            config_targets+=("cix_${CIX_BOARD}.config")
            ;;
    esac
    [[ "${CIX_DOCKER_MODE}" != "docker" ]] || config_targets+=(cix_redroid.config)
    [[ "${CIX_BUILD_MODE}" != "debug" ]] || config_targets+=(cix_debug.config)

    for config_target in "${config_targets[@]}"; do
        [[ -f "${CIX_KERNEL_WORKTREE_SOURCE}/arch/arm64/configs/${config_target}" ]] ||
            cix_die "kernel-owned config is missing: ${config_target}"
    done

    export CIX_NEXUS_SITE="${CIX_NEXUS}"
    export CCACHE_DIR="${CIX_SBUILD_CCACHE_DIR:-${XDG_CACHE_HOME:-${HOME}/.cache}/cix-neo-sbuild/ccache}"
    if command -v ccache >/dev/null && [[ -d /usr/lib/ccache ]]; then
        export PATH="/usr/lib/ccache:${PATH}"
    fi

    cix_log "Configure kernel with: ${config_targets[*]}"
    make -C "${CIX_KERNEL_WORKTREE_SOURCE}" \
        O="${build_dir}" \
        ARCH=arm64 \
        -j"${CIX_JOBS}" \
        "${config_targets[@]}"

    package_args=(
        ARCH=arm64
        LOCALVERSION=-generic
        KDEB_CHANGELOG_DIST="${CIX_DISTRIBUTION}"
        KDEB_SOURCENAME=cix-linux
    )
    [[ -z "${CIX_PACKAGE_VERSION}" ]] ||
        package_args+=(KDEB_PKGVERSION="${CIX_PACKAGE_VERSION}")

    cix_log "Build kernel Debian packages in ${CIX_OUTPUT_DIR}"
    make -C "${CIX_KERNEL_WORKTREE_SOURCE}" \
        O="${build_dir}" \
        -j"${CIX_JOBS}" \
        "${package_args[@]}" \
        bindeb-pkg

    cix_log "Kernel package build complete"
    find "${CIX_OUTPUT_DIR}" -maxdepth 1 -type f -name '*.deb' -printf '    %p\n' | sort
}

cix_stable_kernel_build() {
    local artifacts_dir="${CIX_OUTPUT_DIR}/artifacts"
    local patch_commit
    local patch_remote
    local patch_source="${CIX_WORKSPACE_ROOT}/${CIX_TARGET_PATCH_SOURCE}"
    local stable_source="${CIX_WORKSPACE_ROOT}/${CIX_TARGET_SOURCE}"
    local upstream_builder="${stable_source}/native/build-kernel-native.sh"
    local work_dir="${CIX_OUTPUT_DIR}/work"

    patch_remote="${work_dir}/.cix-linux-main.git"
    [[ -x "${upstream_builder}" ]] ||
        cix_die "stable kernel builder is missing: ${upstream_builder}"
    [[ -d "${patch_source}/.git" || -f "${patch_source}/.git" ]] ||
        cix_die "CIX stable kernel patch source is missing: ${patch_source}"

    if [[ "${CIX_ACTION}" == "clean" ]]; then
        cix_clean_files "${artifacts_dir}" "stable kernel artifacts"
        if [[ -d "${work_dir}" ]]; then
            cix_log "Remove generated stable kernel work files; preserve tarball cache"
            find "${work_dir}" -mindepth 1 -maxdepth 1 \
                ! -name 'linux-*.tar.xz' -delete
        fi
        return 0
    fi

    cix_require_command \
        bc bison curl dpkg-buildpackage fakeroot flex gcc git make nproc openssl \
        pahole realpath rsync tar xz
    [[ -z "$(git -C "${stable_source}" status --porcelain)" ]] ||
        cix_die "stable kernel build harness must be clean: ${stable_source}"
    [[ -z "$(git -C "${patch_source}" status --porcelain)" ]] ||
        cix_die "stable kernel patch source must be clean: ${patch_source}"

    mkdir -p -- "${work_dir}" "${artifacts_dir}"
    patch_commit="$(git -C "${patch_source}" rev-parse HEAD)"
    if [[ ! -d "${patch_remote}" ]]; then
        git init --quiet --bare "${patch_remote}"
    fi
    git -C "${patch_remote}" fetch --quiet --force --no-tags \
        "${patch_source}" "${patch_commit}"
    git -C "${patch_remote}" update-ref refs/heads/main "${patch_commit}"

    export CIX_NEXUS_SITE="${CIX_NEXUS}"
    export KDEB_CHANGELOG_DIST="${CIX_DISTRIBUTION}"
    export OMP_NUM_THREADS="${CIX_JOBS}"
    export OMP_THREAD_LIMIT="${CIX_JOBS}"
    export OUTPUT_DIR="${artifacts_dir}"
    export PATCH_BRANCH=main
    export PATCH_REMOTE="${patch_remote}"
    export WORK_DIR="${work_dir}"
    [[ -z "${CIX_KERNEL_VERSION}" ]] || export KERNEL_VERSION="${CIX_KERNEL_VERSION}"
    [[ -z "${CIX_KERNEL_SERIES}" ]] || export KERNEL_SERIES="${CIX_KERNEL_SERIES}"
    [[ -z "${CIX_KERNEL_TARBALL_URL}" ]] || export KERNEL_TARBALL_URL="${CIX_KERNEL_TARBALL_URL}"
    [[ -z "${CIX_PACKAGE_VERSION}" ]] || export KDEB_PKGVERSION="${CIX_PACKAGE_VERSION}"

    cix_log "Build stable CIX kernel from ${stable_source}"
    cix_log "Use manifest-managed CIX patches at ${patch_commit}"
    (
        cd "${stable_source}/native" || exit
        "${upstream_builder}"
    )
}
