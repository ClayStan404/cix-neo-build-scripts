#!/usr/bin/env bash
# Build and package Radxa Orion platform firmware on native ARM64.

cix_radxa_validate_edk2_inputs() {
    local edk2_source="$1"
    local dependency

    while IFS= read -r dependency; do
        git -C "${edk2_source}/${dependency}" rev-parse \
            --is-inside-work-tree >/dev/null 2>&1 ||
            cix_die "EDK2 dependency is not synced; run repo sync: ${dependency}"
    done < <(
        git -C "${edk2_source}" ls-files --stage |
            awk '$1 == "160000" {print $4}'
    )
}

cix_radxa_remove_worktree() {
    local repository="$1"
    local worktree="$2"

    if git -C "${repository}" worktree list --porcelain |
        awk -v worktree="${worktree}" \
            '$1 == "worktree" && substr($0, 10) == worktree {found = 1}
             END {exit !found}'; then
        git -C "${repository}" worktree remove --force "${worktree}"
    fi
    git -C "${repository}" worktree prune
}

cix_radxa_remove_workspace() {
    local source_root="$1"
    local build_output="$2"
    local work_root="${build_output}/work"
    local work_uefi="${work_root}/uefi_release"

    cix_radxa_remove_worktree \
        "${source_root}/uefi_release/edk2" "${work_uefi}/edk2"
    cix_radxa_remove_worktree \
        "${source_root}/uefi_release/edk2-platforms" \
        "${work_uefi}/edk2-platforms"
    cix_radxa_remove_worktree \
        "${source_root}/uefi_release/edk2-non-osi" \
        "${work_uefi}/edk2-non-osi"
    cix_radxa_remove_worktree \
        "${source_root}/uefi_release/tools/acpica" \
        "${work_uefi}/tools/acpica"

    if [[ -d "${work_root}" ]]; then
        find "${work_root}" -mindepth 1 -delete
        rmdir "${work_root}"
    fi
}

cix_radxa_apply_patch() {
    local repository="$1"
    local patch_file="$2"

    if git -C "${repository}" apply --check --whitespace=nowarn "${patch_file}"; then
        cix_log "Apply $(basename "${patch_file}")"
        git -C "${repository}" apply --whitespace=nowarn "${patch_file}"
    elif git -C "${repository}" apply --reverse --check \
        --whitespace=nowarn "${patch_file}"; then
        cix_log "Skip patch already present upstream: $(basename "${patch_file}")"
    else
        cix_die "firmware patch does not apply cleanly: ${patch_file}"
    fi
}

cix_radxa_prepare_workspace() {
    local source_root="$1"
    local build_output="$2"
    local platform="$3"
    local validation_profile="$4"
    local enable_pm_tuning="$5"
    local source_uefi="${source_root}/uefi_release"
    local work_root="${build_output}/work"
    local work_uefi="${work_root}/uefi_release"
    local patch_root="${CIX_ROOT}/build-scripts/patches/radxa-o6n"
    local pm_patch_root="${CIX_ROOT}/build-scripts/patches/radxa-pm-validation"
    local opp_patch_root="${CIX_ROOT}/build-scripts/patches/radxa-opp-validation"
    local opp_experiment_patch_root="${CIX_ROOT}/build-scripts/patches/radxa-opp-experiments"
    local pm_tuning_patch_root="${CIX_ROOT}/build-scripts/patches/radxa-pm-tuning"
    local dependency
    local dependency_target

    cix_radxa_remove_workspace "${source_root}" "${build_output}"
    mkdir -p -- "${work_uefi}/tools"

    git -C "${source_uefi}/edk2" worktree add --detach \
        "${work_uefi}/edk2" HEAD
    git -C "${source_uefi}/edk2-platforms" worktree add --detach \
        "${work_uefi}/edk2-platforms" HEAD
    git -C "${source_uefi}/edk2-non-osi" worktree add --detach \
        "${work_uefi}/edk2-non-osi" HEAD
    git -C "${source_uefi}/tools/acpica" worktree add --detach \
        "${work_uefi}/tools/acpica" HEAD

    while IFS= read -r dependency; do
        dependency_target="${work_uefi}/edk2/${dependency}"
        if [[ -d "${dependency_target}" ]]; then
            rmdir "${dependency_target}"
        fi
        mkdir -p -- "$(dirname "${dependency_target}")"
        ln -s -- "${source_uefi}/edk2/${dependency}" "${dependency_target}"
    done < <(
        git -C "${source_uefi}/edk2" ls-files --stage |
            awk '$1 == "160000" {print $4}'
    )

    ln -s -- "${source_root}/cix_bsp_release" \
        "${work_root}/cix_bsp_release"

    if [[ "${platform}" == "O6N" ]]; then
        cix_radxa_apply_patch "${work_uefi}/edk2-platforms" \
            "${patch_root}/0001-Platform-Radxa-add-Orion-O6N-support.patch"
        cix_radxa_apply_patch "${work_uefi}/edk2-non-osi" \
            "${patch_root}/0002-Platform-CIX-package-Orion-O6N-firmware.patch"
    fi

    if [[ "${validation_profile}" != "none" ]]; then
        cix_radxa_apply_patch "${work_uefi}/edk2-non-osi" \
            "${pm_patch_root}/0001-PackageTool-add-safe-PM-config-validation-mode.patch"
    fi

    if [[ "${validation_profile}" == "stock-opp" ||
        "${validation_profile}" == "gb1-2700" ]]; then
        cix_radxa_apply_patch "${work_uefi}/edk2-platforms" \
            "${opp_patch_root}/0001-Platform-Radxa-enable-stock-O6-OPP-table.patch"
    fi

    if [[ "${validation_profile}" == "gb1-2700" ]]; then
        cix_radxa_apply_patch "${work_uefi}/edk2-platforms" \
            "${opp_experiment_patch_root}/0001-Platform-Radxa-set-O6-GB1-max-to-2700-MHz.patch"
    fi

    if [[ "${enable_pm_tuning}" == true ]]; then
        cix_radxa_apply_patch "${work_uefi}/edk2-platforms" \
            "${pm_tuning_patch_root}/0001-Platform-add-safe-O6-PM-profile-selection.patch"
    fi
}

cix_direct_radxa_firmware_build() (
    local platform="$1"
    local build_action="$2"
    local build_output="$3"
    local build_jobs="$4"
    local validation_profile=none
    local enable_pm_tuning=false
    local firmware_source="${CIX_ROOT}/${TARGET[source]}"
    local source_uefi="${firmware_source}/uefi_release"
    local uefi_source="${build_output}/work/uefi_release"
    local edk2_source="${uefi_source}/edk2"
    local generated_output="${uefi_source}/output"
    local image_output="${build_output}/images"
    local package_script="${uefi_source}/edk2-non-osi/Platform/CIX/Sky1/PackageTool/build_and_package.sh"
    local package_tool="${uefi_source}/edk2-non-osi/Platform/CIX/Sky1/PackageTool/AARCH64/cix_package_tool"
    local internal_package_script="${firmware_source}/cix_bsp_release/sky1/package_internal_flash_binary.sh"

    if [[ "${TARGET[flow]}" == "radxa-pm-validation" ]]; then
        validation_profile=pmic
    elif [[ "${TARGET[flow]}" == "radxa-opp-validation" ]]; then
        validation_profile=stock-opp
    elif [[ "${TARGET[flow]}" == "radxa-opp-experiment" ]]; then
        validation_profile=gb1-2700
    elif [[ "${TARGET[flow]}" == "radxa-pm-tuning" ]]; then
        validation_profile=stock-opp
        enable_pm_tuning=true
    fi

    if [[ "${build_action}" == "clean" ]]; then
        cix_clean_artifacts "${build_output}"
        cix_radxa_remove_workspace "${firmware_source}" "${build_output}"
        if [[ -d "${image_output}" ]]; then
            cix_log "Remove Radxa ${platform} firmware artifacts"
            find "${image_output}" -mindepth 1 -delete
        fi
        return 0
    fi

    cix_require_command awk file find gcc git make python python3
    [[ -f "${source_uefi}/edk2/edksetup.sh" ]] ||
        cix_die "EDK2 source is missing: ${source_uefi}/edk2"
    cix_radxa_validate_edk2_inputs "${source_uefi}/edk2"

    cix_prepare_host_ccache
    cix_clean_artifacts "${build_output}"
    if [[ -d "${image_output}" ]]; then
        find "${image_output}" -mindepth 1 -delete
    fi
    mkdir -p -- "${image_output}/ocb"
    cix_radxa_prepare_workspace \
        "${firmware_source}" "${build_output}" "${platform}" \
        "${validation_profile}" "${enable_pm_tuning}"

    [[ -x "${package_script}" ]] ||
        cix_die "Radxa firmware package script is missing: ${package_script}"
    [[ -x "${internal_package_script}" ]] ||
        cix_die "CIX internal package script is missing: ${internal_package_script}"
    [[ -x "${package_tool}" ]] ||
        cix_die "native ARM64 CIX package tool is missing: ${package_tool}"
    [[ "$(LC_ALL=C file -b "${package_tool}")" == *"ARM aarch64"* ]] ||
        cix_die "CIX package tool is not an ARM64 executable: ${package_tool}"
    [[ -f "${uefi_source}/edk2-platforms/Platform/Radxa/Orion/${platform}/${platform}.dsc" ]] ||
        cix_die "Radxa ${platform} EDK2 platform description is missing"
    [[ -f "${uefi_source}/tools/acpica/Makefile" ]] ||
        cix_die "ACPICA source is missing: ${uefi_source}/tools/acpica"
    cix_radxa_validate_edk2_inputs "${edk2_source}"

    cix_log "Build EDK2 host tools with ${build_jobs} jobs"
    make -C "${edk2_source}/BaseTools" \
        -j"${build_jobs}" \
        BUILD_LFLAGS=-no-pie \
        EXTRA_LDFLAGS=-no-pie
    make -C "${uefi_source}/tools/acpica" -j"${build_jobs}"

    cix_log "Build Radxa Orion ${platform} firmware with ${build_jobs} jobs"
    if [[ "${validation_profile}" != "none" ]]; then
        (
            cd "${uefi_source}" || exit
            CIX_PM_VALIDATION=1 NETWORK=open \
                "${package_script}" "${platform}"
        )
    else
        (
            cd "${uefi_source}" || exit
            NETWORK=open "${package_script}" "${platform}"
        )
    fi

    cix_log "Generate CIX internal Radxa ${platform} debug images"
    (
        cd "${uefi_source}" || exit
        SOC_TYPE=sky1 MAKEFLAGS="-j${build_jobs}" \
            "${internal_package_script}"
    )

    for artifact in \
        cix_flash_all.bin \
        cix_flash_ota.bin \
        cix_flash_all_rsa_pr_debug.bin \
        cix_flash_ota_rsa_pr_debug.bin; do
        [[ -s "${generated_output}/${artifact}" ]] ||
            cix_die "Radxa ${platform} firmware artifact is missing: ${artifact}"
    done

    if [[ "${validation_profile}" != "none" ]]; then
        local validation_config="${generated_output}/pr/Firmwares/csu_pm_config.bin"
        local validation_output

        [[ -s "${validation_config}" ]] ||
            cix_die "PM validation config is missing: ${validation_config}"
        python3 "${CIX_ROOT}/build-scripts/ci/verify_pm_config.py" \
            --profile "${validation_profile}" "${validation_config}"
        validation_output="${build_output}/csu_pm_config_${platform}_${validation_profile}.bin"
        cp -- "${validation_config}" \
            "${validation_output}"
    fi

    cp -- "${generated_output}/cix_flash_all.bin" \
        "${image_output}/cix_flash_all_${platform}.bin"
    cp -- "${generated_output}/cix_flash_ota.bin" \
        "${image_output}/cix_flash_ota_${platform}.bin"
    cp -- "${generated_output}/cix_flash_all_rsa_pr_debug.bin" \
        "${image_output}/cix_flash_all_${platform}_pr_debug.bin"
    cp -- "${generated_output}/cix_flash_ota_rsa_pr_debug.bin" \
        "${image_output}/cix_flash_ota_${platform}_pr_debug.bin"
    cp -- "${image_output}"/cix_flash_all*.bin "${image_output}/ocb/"

    if [[ -s "${generated_output}/bootloader1_ocb_pr.img" ]]; then
        cp -- "${generated_output}/bootloader1_ocb_pr.img" \
            "${image_output}/ocb/bootloader1_pr.img"
    fi
    if [[ -s "${generated_output}/LinuxLoader.efi.cap" ]]; then
        cp -- "${generated_output}/LinuxLoader.efi.cap" "${build_output}/"
    fi

    cix_radxa_remove_workspace "${firmware_source}" "${build_output}"
    cix_log "Radxa Orion ${platform} firmware build complete"
)
