#!/usr/bin/env bash
# Native kernel flows used by the direct builder.

cix_kernel_patched_worktree() (
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

    cix_prepare_host_ccache
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

cix_stable_kernel_identity() {
    local stable_version="$1"
    local patch_commit="$2"
    local stable_defconfig="$3"
    shift 3

    {
        printf 'version=%s\npatch_commit=%s\n' "${stable_version}" "${patch_commit}"
        sha256sum -- "${stable_defconfig}" "$@"
    } | sha256sum | awk '{ print $1 }'
}

cix_stable_kernel_worktree_matches() {
    local kernel_dir="$1"
    local stable_version="$2"
    local stable_defconfig="$3"
    shift 3
    local actual_patch_id
    local config_line
    local expected_patch_id
    local kernel_version
    local index
    local -a commits=()
    local -a patches=("$@")

    [[ -f "${kernel_dir}/Makefile" && -s "${kernel_dir}/.config" ]] || return 1
    git -C "${kernel_dir}" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
    git -C "${kernel_dir}" diff --quiet -- || return 1
    git -C "${kernel_dir}" diff --cached --quiet -- || return 1
    mapfile -t commits < <(git -C "${kernel_dir}" rev-list --reverse HEAD)
    ((${#commits[@]} == ${#patches[@]} + 1)) || return 1

    kernel_version="$(
        awk -F ' *= *' '
            $1 == "VERSION" { version = $2 }
            $1 == "PATCHLEVEL" { patchlevel = $2 }
            $1 == "SUBLEVEL" { sublevel = $2 }
            END { printf "%s.%s.%s", version, patchlevel, sublevel }
        ' "${kernel_dir}/Makefile"
    )"
    [[ "${kernel_version}" == "${stable_version}" ]] || return 1

    while IFS= read -r config_line || [[ -n "${config_line}" ]]; do
        [[ "${config_line}" == CONFIG_*=* ||
           "${config_line}" == '# CONFIG_'*' is not set' ]] || continue
        grep -Fqx -- "${config_line}" "${kernel_dir}/.config" || return 1
    done <"${stable_defconfig}"

    for ((index = 0; index < ${#patches[@]}; index++)); do
        expected_patch_id="$(git patch-id --stable <"${patches[index]}" | awk 'NR == 1 { print $1 }')"
        actual_patch_id="$(
            git -C "${kernel_dir}" show --pretty=email --binary "${commits[index + 1]}" |
                git patch-id --stable | awk 'NR == 1 { print $1 }'
        )"
        [[ -n "${expected_patch_id}" &&
           "${actual_patch_id}" == "${expected_patch_id}" ]] || return 1
    done
}

cix_kernel_stable_tarball() (
    local build_action="$1"
    local build_output="$2"
    local build_jobs="$3"
    local kernel_dir
    local kernel_series
    local kernel_tarball
    local kernel_url
    local major_version
    local patch_commit
    local patch_source="${CIX_ROOT}/${TARGET[patch_source]}"
    local patchset_dir
    local prepared_identity
    local prepared_marker
    local reuse_worktree=0
    local stable_defconfig
    local stable_version="${TARGET[version]}"
    local tarball_tmp
    local work_dir="${build_output}/work"
    local artifact
    local deb_count=0
    local -a artifacts=()
    local -a patches=()

    kernel_series="${stable_version%.*}"
    major_version="${stable_version%%.*}"
    kernel_tarball="${work_dir}/linux-${stable_version}.tar.xz"
    tarball_tmp="${kernel_tarball}.tmp"
    kernel_dir="${work_dir}/linux-${stable_version}"
    kernel_url="https://cdn.kernel.org/pub/linux/kernel/v${major_version}.x/linux-${stable_version}.tar.xz"
    patchset_dir="${patch_source}/patches-${kernel_series}"
    stable_defconfig="${patch_source}/config/config-${kernel_series}.defconfig"
    prepared_marker="${work_dir}/linux-${stable_version}.prepared"

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
        bc bison curl dpkg-buildpackage fakeroot find flex gcc git make openssl \
        pahole sha256sum sort sync tar xz
    git -C "${patch_source}" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
        cix_die "CIX stable kernel patch source is missing: ${patch_source}"
    [[ -z "$(git -C "${patch_source}" status --porcelain)" ]] ||
        cix_die "stable kernel patch source must be clean: ${patch_source}"
    [[ -d "${patchset_dir}" ]] ||
        cix_die "CIX patch set is missing for Linux ${kernel_series}: ${patchset_dir}"
    [[ -f "${stable_defconfig}" ]] ||
        cix_die "CIX defconfig is missing: ${stable_defconfig}"
    mapfile -d '' -t patches < <(
        find "${patchset_dir}" -maxdepth 1 -type f -name '*.patch' -print0 |
            LC_ALL=C sort -z
    )
    ((${#patches[@]} > 0)) || cix_die "CIX patch set is empty: ${patchset_dir}"

    cix_prepare_host_ccache
    mkdir -p -- "${work_dir}" "${build_output}"
    cix_clean_artifacts "${build_output}"
    patch_commit="$(git -C "${patch_source}" rev-parse HEAD)"
    prepared_identity="$(
        cix_stable_kernel_identity \
            "${stable_version}" "${patch_commit}" "${stable_defconfig}" \
            "${patches[@]}"
    )"

    if [[ -f "${kernel_tarball}" ]]; then
        cix_log "Use cached Linux tarball: ${kernel_tarball}"
    else
        trap 'rm -f -- "${tarball_tmp}"' EXIT
        cix_log "Download ${kernel_url}"
        curl -fL --retry 3 -o "${tarball_tmp}" "${kernel_url}"
        sync "${tarball_tmp}"
        xz -t "${tarball_tmp}"
        mv -- "${tarball_tmp}" "${kernel_tarball}"
        trap - EXIT
    fi
    xz -t "${kernel_tarball}"

    if [[ "${resume_build:-0}" == 1 && -d "${kernel_dir}" ]]; then
        if cix_stable_kernel_worktree_matches \
            "${kernel_dir}" "${stable_version}" "${stable_defconfig}" \
            "${patches[@]}"; then
            if [[ ! -f "${prepared_marker}" ||
                  "$(<"${prepared_marker}")" != "${prepared_identity}" ]]; then
                cix_log "Adopt verified interrupted Linux ${stable_version} worktree"
                printf '%s\n' "${prepared_identity}" >"${prepared_marker}"
            fi
            reuse_worktree=1
        fi
    fi

    if ((reuse_worktree)); then
        cix_require_free_gib "${work_dir}" 8 "resuming the stable kernel package build"
        cix_log "Resume verified Linux ${stable_version} worktree"
    else
        if [[ -d "${kernel_dir}" ]]; then
            cix_log "Replace previous stable kernel source: ${kernel_dir}"
            rm -rf -- "${kernel_dir}"
        fi
        rm -f -- "${prepared_marker}"
        cix_require_free_gib "${work_dir}" 40 "building the stable kernel from scratch"
        cix_log "Extract Linux ${stable_version}"
        tar -xf "${kernel_tarball}" -C "${work_dir}"
        [[ -f "${kernel_dir}/Makefile" ]] ||
            cix_die "extracted Linux source is missing: ${kernel_dir}"

        cix_log "Apply ${#patches[@]} CIX patches from ${patch_commit}"
        git -C "${kernel_dir}" init --quiet
        git -C "${kernel_dir}" \
            -c user.name=build \
            -c user.email=build@localhost \
            -c commit.gpgsign=false \
            add -A
        git -C "${kernel_dir}" \
            -c user.name=build \
            -c user.email=build@localhost \
            -c commit.gpgsign=false \
            commit --quiet -m "import linux-${stable_version}"
        git -C "${kernel_dir}" \
            -c user.name=build \
            -c user.email=build@localhost \
            -c commit.gpgsign=false \
            am --whitespace=nowarn "${patches[@]}"

        cp -- "${stable_defconfig}" "${kernel_dir}/.config"
        cix_log "Configure Linux ${stable_version} with CIX ${kernel_series} defconfig"
        make -C "${kernel_dir}" ARCH=arm64 olddefconfig
        printf '%s\n' "${prepared_identity}" >"${prepared_marker}"
    fi

    find "${work_dir}" -mindepth 1 -maxdepth 1 -type f \
        \( -name 'linux-*.deb' -o -name 'linux-*.buildinfo' -o -name 'linux-*.changes' \) \
        -delete

    cix_log "Build stable kernel Debian packages with ${build_jobs} jobs"
    make -C "${kernel_dir}" \
        -j"${build_jobs}" \
        ARCH=arm64 \
        "DPKG_FLAGS=--jobs=${build_jobs}" \
        "KDEB_CHANGELOG_DIST=${CIX_SUITE}" \
        LOCALVERSION=-cix \
        bindeb-pkg

    shopt -s nullglob
    artifacts=(
        "${work_dir}"/linux-*.deb
        "${work_dir}"/linux-*.buildinfo
        "${work_dir}"/linux-*.changes
    )
    for artifact in "${artifacts[@]}"; do
        [[ "${artifact}" == *.deb ]] && ((deb_count += 1))
    done
    ((deb_count > 0)) || cix_die "stable kernel build produced no Debian packages"
    mv -f -- "${artifacts[@]}" "${build_output}/"
    cix_log "Remove completed stable kernel worktree"
    rm -rf -- "${kernel_dir}"
    rm -f -- "${prepared_marker}"
    cix_log "Stable kernel package build complete"
)

cix_direct_kernel_build() {
    local build_action="$1"
    local build_output="$2"
    local build_jobs="$3"

    case "${TARGET[flow]}" in
        kernel-worktree)
            cix_kernel_patched_worktree \
                "${build_action}" "${build_output}" "${build_jobs}"
            ;;
        kernel-stable-tarball)
            cix_kernel_stable_tarball \
                "${build_action}" "${build_output}" "${build_jobs}"
            ;;
        *)
            cix_die "unsupported kernel flow: ${TARGET[flow]}"
            ;;
    esac
}
