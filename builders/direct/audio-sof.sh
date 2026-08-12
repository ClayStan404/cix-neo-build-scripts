#!/usr/bin/env bash
# Build CIX SOF firmware with an ARM64-hosted Xtensa toolchain.

cix_audio_sof_git_commit() {
    git -C "$1" rev-parse HEAD
}

cix_audio_sof_validate_source() {
    local source_dir="$1"

    git -C "${source_dir}" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
        cix_die "SOF build input is not a Git worktree: ${source_dir}"
}

cix_audio_sof_validate_toolchain() {
    local compiler="$1"
    local compiler_description

    [[ -x "${compiler}" ]] || return 1
    compiler_description="$(LC_ALL=C file -b "${compiler}")"
    [[ "${compiler_description}" == *"ARM aarch64"* ]] || return 1
    LC_ALL=C readelf -h "${compiler}" | grep -q 'Machine:.*AArch64' || return 1
    "${compiler}" --version >/dev/null 2>&1
    [[ "$("${compiler}" -dumpmachine)" == "xtensa-sky1-elf" ]]
}

cix_audio_sof_prepare_toolchain() (
    local audio_source="$1"
    local build_output="$2"
    local build_jobs="$3"
    local compiler
    local crosstool_commit
    local crosstool_source="${audio_source}/crosstool-ng"
    local crosstool_work="${build_output}/work/crosstool-ng"
    local host_tools="${build_output}/host-tools"
    local newlib_commit
    local newlib_source="${audio_source}/newlib-xtensa"
    local overlay_commit
    local overlay_source="${audio_source}/xtensa-overlay"
    local source_id
    local stamp
    local stamp_tmp
    local toolchain="${build_output}/toolchain/xtensa-sky1-elf"

    compiler="${toolchain}/bin/xtensa-sky1-elf-gcc"
    stamp="${toolchain}/.cix-source-id"
    crosstool_commit="$(cix_audio_sof_git_commit "${crosstool_source}")"
    newlib_commit="$(cix_audio_sof_git_commit "${newlib_source}")"
    overlay_commit="$(cix_audio_sof_git_commit "${overlay_source}")"
    source_id="$({
        printf 'recipe 1\n'
        printf 'crosstool-ng %s\n' "${crosstool_commit}"
        printf 'newlib-xtensa %s\n' "${newlib_commit}"
        printf 'xtensa-overlay %s\n' "${overlay_commit}"
        printf 'host-gcc %s\n' "$(gcc-12 -dumpfullversion)"
    })"

    if [[ -f "${stamp}" ]] &&
        [[ "$(<"${stamp}")" == "${source_id}" ]] &&
        cix_audio_sof_validate_toolchain "${compiler}"; then
        cix_log "Use cached ARM64 Xtensa toolchain: ${toolchain}"
        return 0
    fi

    cix_log "Build ARM64-hosted Xtensa toolchain from manifest sources"
    mkdir -p -- "${crosstool_work}" "${host_tools}" "${build_output}/downloads"
    if [[ -d "${toolchain}" ]]; then
        find "${toolchain}" -type d -exec chmod u+w -- {} +
        find "${toolchain}" -mindepth 1 -delete
    fi
    find "${crosstool_work}" -mindepth 1 -delete
    rsync -a \
        --exclude=/.git/ \
        --exclude=/.build/ \
        --exclude=/builds/ \
        "${crosstool_source}/" "${crosstool_work}/"
    ln -sfn -- "${overlay_source}" "${build_output}/work/xtensa-overlay"

    # crosstool-NG rejects CC/CXX in its build environment. Put GCC 12 first
    # in PATH instead; GCC 14 cannot build this older GCC 10.2 toolchain.
    ln -sfn /usr/bin/gcc-12 "${host_tools}/cc"
    ln -sfn /usr/bin/gcc-12 "${host_tools}/gcc"
    ln -sfn /usr/bin/g++-12 "${host_tools}/c++"
    ln -sfn /usr/bin/g++-12 "${host_tools}/g++"

    (
        cd "${crosstool_work}" || exit
        CC=gcc-12 CXX=g++-12 ./bootstrap
        CC=gcc-12 CXX=g++-12 ./configure --prefix="${crosstool_work}"
        make -j"${build_jobs}"
        make install

        cp -- config-sky1-gcc10.2-gdb9 .config
        sed -i \
            -e "s|^CT_LOCAL_TARBALLS_DIR=.*|CT_LOCAL_TARBALLS_DIR=\"${build_output}/downloads\"|" \
            -e "s|^CT_PREFIX_DIR=.*|CT_PREFIX_DIR=\"${build_output}/toolchain/\${CT_TARGET}\"|" \
            -e 's|^CT_LOG_PROGRESS_BAR=y|# CT_LOG_PROGRESS_BAR is not set|' \
            -e 's|^CT_DEBUG_GDB=y|# CT_DEBUG_GDB is not set|' \
            -e "s|^CT_NEWLIB_DEVEL_URL=.*|CT_NEWLIB_DEVEL_URL=\"file://${newlib_source}\"|" \
            -e 's|^CT_NEWLIB_DEVEL_BRANCH=.*|CT_NEWLIB_DEVEL_BRANCH=""|' \
            -e "s|^CT_NEWLIB_DEVEL_REVISION=.*|CT_NEWLIB_DEVEL_REVISION=\"${newlib_commit}\"|" \
            .config
        ./ct-ng olddefconfig
        PATH="${host_tools}:${PATH}" ./ct-ng "build.${build_jobs}"
    )

    cix_audio_sof_validate_toolchain "${compiler}" ||
        cix_die "generated Xtensa compiler is not executable on ARM64: ${compiler}"
    chmod u+w -- "${toolchain}"
    if [[ -d "${crosstool_work}/.build" ]]; then
        cix_log "Remove completed crosstool-NG intermediate build files"
        find "${crosstool_work}/.build" -mindepth 0 -delete
    fi
    stamp_tmp="${stamp}.tmp"
    printf '%s\n' "${source_id}" > "${stamp_tmp}"
    mv -f -- "${stamp_tmp}" "${stamp}"
)

cix_audio_sof_source_epoch() {
    local audio_source="$1"
    local epoch
    local repository
    local latest=0

    for repository in "${audio_source}"/*; do
        epoch="$(git -C "${repository}" log -1 --format=%ct)"
        ((epoch > latest)) && latest="${epoch}"
    done
    printf '%s\n' "${latest}"
}

cix_direct_audio_sof_build() (
    local build_action="$1"
    local build_output="$2"
    local build_jobs="$3"
    local audio_source="${CIX_ROOT}/${TARGET[source]}"
    local packaging_dir="${CIX_ROOT}/${TARGET[debian]}"
    local packaging_epoch
    local package_tree
    local source_package
    local sof_commit
    local sof_source="${audio_source}/sof"
    local sof_work="${build_output}/work/sof"
    local source_epoch
    local tomlc_source="${audio_source}/tomlc99"
    local tomlc_work="${build_output}/work/tomlc99"
    local toolchain="${build_output}/toolchain/xtensa-sky1-elf"
    local toolchain_view="${build_output}/work/xtensa-sky1-elf"
    local topology_dir="${sof_work}/tools/build_tools/topology/topology1/production"
    local artifact
    local -a firmware=(
        build_sky1_gcc/sof-sky1.ri
        build_sky1_gcc/sof-sky1.ldc
        build_sky1p_gcc/sof-sky1p.ri
        build_sky1p_gcc/sof-sky1p.ldc
    )
    local -a required_topologies=(
        sof-sky1-alc5682-alc1019.tplg
        sof-sky1-i2ssc0-tdm8-4x2ch.tplg
        sof-sky1p-alc5682.tplg
        sof-sky1p-alc5682-alc1019.tplg
    )
    local -a topologies=()

    if [[ "${build_action}" == "clean" ]]; then
        cix_clean_artifacts "${build_output}"
        if [[ -d "${build_output}/work" ]]; then
            cix_log "Remove generated SOF firmware and packaging work files"
            find "${build_output}/work" -mindepth 1 -maxdepth 1 \
                \( -name sof -o -name tomlc99 -o -name package -o \
                   -name xtensa-root -o -name xtensa-sky1-elf \) \
                -exec rm -rf -- {} +
        fi
        return 0
    fi

    cix_require_command \
        alsatplg autoconf automake cmake dpkg-buildpackage file find g++-12 \
        gcc-12 git grep m4 make ninja readelf rsync sed sort
    for artifact in crosstool-ng newlib-xtensa sof tomlc99 xtensa-overlay; do
        [[ -d "${audio_source}/${artifact}" ]] ||
            cix_die "SOF build input is missing: ${audio_source}/${artifact}"
        cix_audio_sof_validate_source "${audio_source}/${artifact}"
    done
    [[ -f "${packaging_dir}/control" && -f "${packaging_dir}/changelog" ]] ||
        cix_die "SOF Debian metadata is missing: ${packaging_dir}"
    [[ "$(<"${packaging_dir}/source/format")" == "3.0 (native)" ]] ||
        cix_die "SOF Debian metadata must use source format 3.0 (native)"
    read -r source_package _ _ < <(cix_debian_metadata "${packaging_dir}")
    package_tree="${build_output}/work/package/${source_package}"

    mkdir -p -- "${build_output}/work" "${build_output}/toolchain"
    cix_clean_artifacts "${build_output}"
    cix_audio_sof_prepare_toolchain \
        "${audio_source}" "${build_output}" "${build_jobs}"

    cix_prepare_host_ccache
    if [[ -L "${toolchain_view}" ]]; then
        find "${toolchain_view}" -maxdepth 0 -type l -delete
    fi
    mkdir -p -- "${sof_work}" "${tomlc_work}" "${toolchain_view}/bin"
    find "${toolchain_view}/bin" -mindepth 1 -delete
    ln -s -- /usr/bin/ccache \
        "${toolchain_view}/bin/xtensa-sky1-elf-gcc"
    find "${sof_work}" -mindepth 1 -delete
    find "${tomlc_work}" -mindepth 1 -delete
    rsync -a --exclude=/.git/ "${sof_source}/" "${sof_work}/"
    rsync -a --exclude=/.git/ "${tomlc_source}/" "${tomlc_work}/"
    sof_commit="$(cix_audio_sof_git_commit "${sof_source}")"
    printf 'v2.11.2-cix\n%s\n' "${sof_commit}" > "${sof_work}/.tarball-version"
    ln -sfn -- ../../../tomlc99 "${sof_work}/tools/rimage/tomlc99"
    mkdir -p -- "${build_output}/work/xtensa-root"
    ln -sfn -- ../../toolchain/xtensa-sky1-elf/xtensa-sky1-elf \
        "${build_output}/work/xtensa-root/xtensa-sky1-elf"

    cix_log "Build Sky1 and Sky1P SOF firmware with ${build_jobs} jobs"
    (
        cd "${sof_work}" || exit
        PATH="${toolchain_view}/bin:${toolchain}/bin:${PATH}" \
            ./scripts/xtensa-build-all.sh -j "${build_jobs}" sky1 sky1p
        NO_PROCESSORS="${build_jobs}" ./scripts/build-tools.sh -T
    )

    for artifact in "${firmware[@]}"; do
        [[ -s "${sof_work}/${artifact}" ]] ||
            cix_die "SOF firmware artifact is missing: ${artifact}"
    done
    mapfile -d '' -t topologies < <(
        find "${topology_dir}" -maxdepth 1 -type f \
            -name 'sof-sky1*.tplg' -printf '%f\0' | LC_ALL=C sort -z
    )
    ((${#topologies[@]} > 0)) || cix_die "SOF build produced no CIX topologies"
    for artifact in "${topologies[@]}"; do
        [[ -s "${topology_dir}/${artifact}" ]] ||
            cix_die "SOF topology artifact is missing: ${artifact}"
    done
    for artifact in "${required_topologies[@]}"; do
        [[ -s "${topology_dir}/${artifact}" ]] ||
            cix_die "required CIX topology artifact is missing: ${artifact}"
    done

    if [[ -d "${package_tree}" ]]; then
        find "${package_tree}" -mindepth 1 -delete
    fi
    mkdir -p -- \
        "${package_tree}/firmware" "${package_tree}/topology" \
        "${package_tree}/debian"
    for artifact in "${firmware[@]}"; do
        cp -- "${sof_work}/${artifact}" "${package_tree}/firmware/"
    done
    for artifact in "${topologies[@]}"; do
        cp -- "${topology_dir}/${artifact}" "${package_tree}/topology/"
    done
    rsync -a "${packaging_dir}/" "${package_tree}/debian/"

    source_epoch="$(cix_audio_sof_source_epoch "${audio_source}")"
    packaging_epoch="$(git -C "${packaging_dir}" log -1 --format=%ct)"
    if ((packaging_epoch > source_epoch)); then
        source_epoch="${packaging_epoch}"
    fi
    cix_run_local_dpkg \
        "${package_tree}" "${source_epoch}" "${build_output}" "${build_jobs}"
    cix_log "CIX SOF firmware package build complete"
)
