#!/usr/bin/env bash
# Build and package Radxa Orion platform firmware on native ARM64.

# shellcheck source=builders/direct/bootloader1.sh
source "${CIX_ROOT}/build-scripts/builders/direct/bootloader1.sh"

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
    local source_edk2="${source_root}/uefi_release/edk2"
    local work_root="${build_output}/work"
    local work_uefi="${work_root}/uefi_release"
    local dependency

    cix_bootloader1_remove_workspace "${source_root}" "${build_output}"

    while IFS= read -r dependency; do
        cix_radxa_remove_worktree \
            "${source_edk2}/${dependency}" \
            "${work_uefi}/edk2/${dependency}"
    done < <(
        git -C "${source_edk2}" ls-files --stage |
            awk '$1 == "160000" {print $4}'
    )

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

cix_radxa_validate_pm_ifr() {
    local platform_config_ifr="$1"
    local capability="$2"

    awk -v capability="${capability}" '
        /form formid = 0x2017,/ { profile_form = 1 }
        /form formid = 0x2018,/ { custom_form = 1 }
        /oneof varid = RadxaPmTuningVar.Profile,/ {
            selector = 1
            in_profile_selector = 1
        }
        in_profile_selector && /option text =/ { profile_options++ }
        in_profile_selector && /endoneof;/ { in_profile_selector = 0 }
        /numeric varid = RadxaPmTuningVar.CpuFrequency\[0\],/ {
            first_frequency = 1
        }
        /numeric varid = RadxaPmTuningVar.CpuFrequency\[[0-9]+\],/ {
            frequency_fields++
        }
        /numeric varid = RadxaPmTuningVar.CpuVoltage\[44\],/ {
            last_voltage = 1
        }
        /numeric varid = RadxaPmTuningVar.CpuVoltage\[[0-9]+\],/ {
            voltage_fields++
        }
        /oneof varid = RadxaPmTuningVar.CpuVoltageMode\[[0-9]+\],/ {
            vmin_fields++
        }
        /oneof varid = RadxaPmTuningVar.CpuDomainEnabled\[[0-9]+\],/ {
            partial_domains++
        }
        /CpuFrequency\[(2|15|28|41)\]/ ||
        /CpuVoltage\[(2|15|28|41)\]/ ||
        /CpuVoltageMode\[(2|15|28|41)\]/ { protected_opp = 1 }
        END {
            expected_options = (capability == "engineering") ? 4 : 2
            exit !(profile_form && custom_form && selector &&
                   first_frequency && last_voltage &&
                   frequency_fields == 23 && voltage_fields == 23 &&
                   vmin_fields == 23 && partial_domains == 4 &&
                   profile_options == expected_options && !protected_opp)
        }
    ' "${platform_config_ifr}" ||
        cix_die "compiled O6 ${capability} firmware has an invalid PM menu"
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
    local memory_tuning_patch_root="${CIX_ROOT}/build-scripts/patches/radxa-memory-tuning"
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
        git -C "${source_uefi}/edk2/${dependency}" worktree add --detach \
            "${dependency_target}" HEAD
    done < <(
        git -C "${source_uefi}/edk2" ls-files --stage |
            awk '$1 == "160000" {print $4}'
    )

    if [[ "${enable_pm_tuning}" == true ]]; then
        cp -a --reflink=auto -- "${source_root}/cix_bsp_release" \
            "${work_root}/cix_bsp_release"
    else
        ln -s -- "${source_root}/cix_bsp_release" \
            "${work_root}/cix_bsp_release"
    fi

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
        "${validation_profile}" == "vendor-auto" ||
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
            "${pm_tuning_patch_root}/0001-Platform-add-selectable-O6-PM-profiles.patch"
        cix_radxa_apply_patch "${work_uefi}/edk2-non-osi" \
            "${pm_tuning_patch_root}/0002-PackageTool-select-PM-engineering-capabilities.patch"
        cix_radxa_apply_patch "${work_uefi}/edk2-platforms" \
            "${memory_tuning_patch_root}/0001-Make-O6-memory-rate-updates-reliable.patch"

        local pm_form="${work_uefi}/edk2-platforms/Platform/Radxa/Platforms/CIX/Sky1/Drivers/PlatformConfigDxe/PmMenu/PmConfig.hfr"
        local memory_form="${work_uefi}/edk2-platforms/Platform/Radxa/Platforms/CIX/Sky1/Drivers/PlatformConfigDxe/MemMenu/MemoryConfig.hfr"
        local memory_updater="${work_uefi}/edk2-platforms/Platform/CIX/Sky1/Drivers/MemConfigUpdateDxe/MemConfigUpdateDxe.c"
        [[ -s "${pm_form}" ]] || cix_die "O6 custom PM form is missing"
        [[ -s "${memory_form}" ]] || cix_die "O6 memory configuration form is missing"
        [[ -s "${memory_updater}" ]] || cix_die "O6 memory updater is missing"
        awk '
            /CpuFrequency\[(2|15|28|41)\]/ ||
            /CpuVoltage\[(2|15|28|41)\]/ ||
            /CpuVoltageMode\[(2|15|28|41)\]/ { protected_opp = 1 }
            END { exit protected_opp }
        ' "${pm_form}" ||
            cix_die "O6 custom PM form exposes the protected boot OPP"
        awk '
            /minimum = 800, maximum = 3200, step = 10/ {
                frequency_boundary = 1
            }
            /minimum = 550, maximum = 1250, step = 10/ {
                voltage_boundary = 1
            }
            END { exit !(frequency_boundary && voltage_boundary) }
        ' "${pm_form}" ||
            cix_die "O6 custom PM form has unexpected input boundaries"
        awk '
            /RADXA_PM_PROFILE_PARTIAL/ { partial_profile = 1 }
            /RadxaPmTuningVar.CpuDomainEnabled\[Index\]/ { partial_macro = 1 }
            /PM_DOMAIN_ENABLE\(0\)/ { partial_domain = 1 }
            /RadxaPmTuningVar.CpuVoltageMode\[Index\]/ { vmin_macro = 1 }
            /PM_VOLT_MODE\(0\)/ { vmin_policy = 1 }
            /PM_FREQ_AFTER_BOOT\(3, 4, 1800\)/ { editable_opp3 = 1 }
            /STR_PM_PARTIAL_REQUIRED/ { partial_required = 1 }
            /PM_ENGINEERING_SUPPORT/ { engineering_gate = 1 }
            END {
                exit !(partial_profile && partial_macro && partial_domain &&
                       vmin_macro && vmin_policy && editable_opp3 &&
                       partial_required && engineering_gate)
            }
        ' "${pm_form}" ||
            cix_die "O6 custom PM form is missing partial-domain or Vmin controls"
        awk '
            /PmConservativePower \(/ { conservative_power = 1 }
            /PM_CONFIG_VMIN_VOLTAGE_CEILING/ { vmin_ceiling = 1 }
            /EnabledDomains == 0/ { partial_nonempty = 1 }
            /RADXA_PM_TUNING_REVISION/ { settings_revision = 1 }
            /PM_ENGINEERING_SUPPORT == 0/ { engineering_gate = 1 }
            END {
                exit !(conservative_power && vmin_ceiling && partial_nonempty &&
                       settings_revision && engineering_gate)
            }
        ' "${work_uefi}/edk2-platforms/Platform/CIX/Sky1/Drivers/PmConfigUpdateDxe/PmConfigUpdateDxe.c" ||
            cix_die "O6 PM updater is missing a safety policy"
        awk '
            /STR_DDR_1600.*value = 800/ { rate_1600 = 1 }
            /STR_DDR_2133.*value = 1067/ { rate_2133 = 1 }
            /STR_DDR_2750.*value = 1375/ { rate_2750 = 1 }
            /STR_DDR_3200.*value = 1600/ { rate_3200 = 1 }
            /STR_DDR_3733.*value = 1867/ { rate_3733 = 1 }
            /STR_DDR_4266.*value = 2133/ { rate_4266 = 1 }
            /STR_DDR_4800.*value = 2400/ { rate_4800 = 1 }
            /STR_DDR_5500.*value = 2750/ { rate_5500 = 1 }
            /STR_DDR_6000.*value = 3000/ { rate_6000 = 1 }
            /STR_DDR_6400.*value = 3200/ { rate_6400 = 1 }
            /STR_AUTO.*value = 0xFFFF/ { automatic = 1 }
            END {
                exit !(rate_1600 && rate_2133 && rate_2750 && rate_3200 &&
                       rate_3733 && rate_4266 && rate_4800 && rate_5500 &&
                       rate_6000 && rate_6400 && automatic)
            }
        ' "${memory_form}" ||
            cix_die "O6 memory form is missing an expected explicit or Auto data rate"
        awk '
            /O6MemoryFrequencyIsValid \(/ { validates_rate = 1 }
            /pPlatformSetupData->MemFreq != MemConfigBiosSetup->MemFreq/ {
                updates_bset = 1
            }
            /Config->MaxFreq[[:space:]]*=/ { rewrites_conf = 1 }
            /Memory configuration write verified/ { readback = 1 }
            END {
                exit !(validates_rate && updates_bset && readback && !rewrites_conf)
            }
        ' "${memory_updater}" ||
            cix_die "O6 memory updater must update only BSET and verify the flash write"
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
    local internal_package_script="${build_output}/work/cix_bsp_release/sky1/package_internal_flash_binary.sh"
    local platform_config_ifr
    local release_bootloader3="${build_output}/bootloader3_vendor_release.img"
    local release_platform_config_ifr="${build_output}/PlatformConfigHii.vendor_release.i"
    local debug_bootloader3="${build_output}/bootloader3_engineering_debug.img"

    if [[ "${TARGET[flow]}" == "radxa-pm-validation" ]]; then
        validation_profile=pmic
    elif [[ "${TARGET[flow]}" == "radxa-opp-validation" ]]; then
        validation_profile=stock-opp
    elif [[ "${TARGET[flow]}" == "radxa-opp-experiment" ]]; then
        validation_profile=gb1-2700
    elif [[ "${TARGET[flow]}" == "radxa-pm-tuning" ]]; then
        validation_profile=vendor-auto
        enable_pm_tuning=true
    fi

    if [[ "${build_action}" == "clean" ]]; then
        cix_clean_artifacts "${build_output}"
        cix_radxa_remove_workspace "${firmware_source}" "${build_output}"
        if [[ "${enable_pm_tuning}" == true ]]; then
            cix_bootloader1_clean_artifacts "${build_output}"
        fi
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

    if [[ "${enable_pm_tuning}" == true ]]; then
        local pm_firmware_root="${firmware_source}/bootloader/firmware-binaries/sky1/evb"

        python3 "${CIX_ROOT}/build-scripts/ci/verify_pm_firmware.py" \
            --build-type debug "${pm_firmware_root}/debug/pm_fw/pm_fw.bin"
        python3 "${CIX_ROOT}/build-scripts/ci/verify_pm_firmware.py" \
            --build-type release "${pm_firmware_root}/release/pm_fw/pm_fw.bin"
        cix_require_command \
            arm-none-eabi-gcc arm-none-eabi-ld arm-none-eabi-objcopy \
            cmp install openssl pkg-config sha256sum
        cix_bootloader1_build \
            "${firmware_source}" "${build_output}" "${build_jobs}" \
            "${build_output}/work/cix_bsp_release"
    fi

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

    if [[ "${enable_pm_tuning}" == true ]]; then
        cix_log "Build Radxa Orion ${platform} vendor-capped UEFI with ${build_jobs} jobs"
        (
            cd "${uefi_source}" || exit
            CIX_PM_VALIDATION=1 CIX_PM_ENGINEERING=FALSE NETWORK=open \
                "${package_script}" "${platform}"
        )
        platform_config_ifr="$(
            find "${uefi_source}/Build/${platform}" \
                -path '*/PlatformConfigDxe/PlatformConfigDxe/OUTPUT/PlatformConfigHii.i' \
                -print -quit
        )"
        [[ -s "${platform_config_ifr}" ]] ||
            cix_die "compiled O6 vendor-capped platform configuration form is missing"
        cix_radxa_validate_pm_ifr "${platform_config_ifr}" vendor
        cp -- "${platform_config_ifr}" "${release_platform_config_ifr}"
        cp -- "${generated_output}/pr/Firmwares/bootloader3.img" \
            "${release_bootloader3}"

        cix_log "Build Radxa Orion ${platform} engineering UEFI with ${build_jobs} jobs"
        (
            cd "${uefi_source}" || exit
            CIX_PM_VALIDATION=1 CIX_PM_ENGINEERING=TRUE NETWORK=open \
                "${package_script}" "${platform}"
        )
        cp -- "${generated_output}/pr/Firmwares/bootloader3.img" \
            "${debug_bootloader3}"
    elif [[ "${validation_profile}" != "none" ]]; then
        cix_log "Build Radxa Orion ${platform} firmware with ${build_jobs} jobs"
        (
            cd "${uefi_source}" || exit
            CIX_PM_VALIDATION=1 NETWORK=open \
                "${package_script}" "${platform}"
        )
    else
        cix_log "Build Radxa Orion ${platform} firmware with ${build_jobs} jobs"
        (
            cd "${uefi_source}" || exit
            NETWORK=open "${package_script}" "${platform}"
        )
    fi

    if [[ "${enable_pm_tuning}" == true ]]; then
        platform_config_ifr="$(
            find "${uefi_source}/Build/${platform}" \
                -path '*/PlatformConfigDxe/PlatformConfigDxe/OUTPUT/PlatformConfigHii.i' \
                -print -quit
        )"
        [[ -s "${platform_config_ifr}" ]] ||
            cix_die "compiled O6 engineering platform configuration form is missing"
        cix_radxa_validate_pm_ifr "${platform_config_ifr}" engineering
        python3 "${CIX_ROOT}/build-scripts/ci/verify_memory_config.py" \
            "${generated_output}/pr/Firmwares/memory_config.bin"
        cix_log "Verified O6 PM and experimental memory tuning firmware"
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

    if [[ "${enable_pm_tuning}" == true ]]; then
        for artifact in \
            cix_flash_all_rsa_proto.bin \
            cix_flash_all_rsa_proto_debug.bin; do
            [[ -s "${generated_output}/${artifact}" ]] ||
                cix_die "Radxa ${platform} prototype artifact is missing: ${artifact}"
        done

        if cmp -s -- \
            "${generated_output}/cix_flash_all_rsa_proto.bin" \
            "${generated_output}/cix_flash_all_rsa_proto_debug.bin"; then
            cix_die "prototype release and debug full-flash images are identical"
        fi

        cp -- "${release_bootloader3}" \
            "${generated_output}/proto_release/Firmwares/bootloader3.img"
        (
            cd "${generated_output}/proto_release" || exit
            ./cix_package_tool -c spi_flash_config_all.json \
                -o "${generated_output}/cix_flash_all_rsa_proto.bin"
        )
        cmp -- "${release_bootloader3}" \
            "${generated_output}/proto_release/Firmwares/bootloader3.img" ||
            cix_die "prototype release image does not contain vendor-capped UEFI"
        cmp -- "${debug_bootloader3}" \
            "${generated_output}/proto_debug/Firmwares/bootloader3.img" ||
            cix_die "prototype debug image does not contain engineering UEFI"
        if cmp -s -- \
            "${generated_output}/cix_flash_all_rsa_proto.bin" \
            "${generated_output}/cix_flash_all_rsa_proto_debug.bin"; then
            cix_die "final vendor and engineering full-flash images are identical"
        fi

        cmp -- "${build_output}/bootloader1/bootloader1_proto_release.img" \
            "${generated_output}/proto_release/Firmwares/bootloader1.img" ||
            cix_die "prototype release image does not contain the source-built bootloader1"
        cmp -- "${build_output}/bootloader1/bootloader1_proto_debug.img" \
            "${generated_output}/proto_debug/Firmwares/bootloader1.img" ||
            cix_die "prototype debug image does not contain the source-built bootloader1"
        cmp -- \
            "${firmware_source}/cix_bsp_release/sky1/pr_debug/Firmwares/bootloader1.img" \
            "${generated_output}/pr_debug/Firmwares/bootloader1.img" ||
            cix_die "the revision-pinned pr bootloader1 was unexpectedly replaced"
        cmp -- \
            "${firmware_source}/cix_bsp_release/sky1/pr2_debug/Firmwares/bootloader1.img" \
            "${generated_output}/pr2_debug/Firmwares/bootloader1.img" ||
            cix_die "the revision-pinned pr2 bootloader1 was unexpectedly replaced"
        cix_log "Verified local prototype and revision-pinned product signing boundaries"
    fi

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

    if [[ "${enable_pm_tuning}" == true ]]; then
        cp -- "${generated_output}/cix_flash_all_rsa_proto.bin" \
            "${image_output}/cix_flash_all_${platform}_vendor_release.bin"
        cp -- "${generated_output}/cix_flash_all_rsa_proto_debug.bin" \
            "${image_output}/cix_flash_all_${platform}_engineering_debug.bin"
    else
        cp -- "${generated_output}/cix_flash_all.bin" \
            "${image_output}/cix_flash_all_${platform}.bin"
        cp -- "${generated_output}/cix_flash_ota.bin" \
            "${image_output}/cix_flash_ota_${platform}.bin"
        cp -- "${generated_output}/cix_flash_all_rsa_pr_debug.bin" \
            "${image_output}/cix_flash_all_${platform}_pr_debug.bin"
        cp -- "${generated_output}/cix_flash_ota_rsa_pr_debug.bin" \
            "${image_output}/cix_flash_ota_${platform}_pr_debug.bin"
    fi
    cp -- "${image_output}"/cix_flash_all*.bin "${image_output}/ocb/"

    if [[ "${enable_pm_tuning}" != true &&
        -s "${generated_output}/bootloader1_ocb_pr.img" ]]; then
        cp -- "${generated_output}/bootloader1_ocb_pr.img" \
            "${image_output}/ocb/bootloader1_pr.img"
    fi
    if [[ -s "${generated_output}/LinuxLoader.efi.cap" ]]; then
        cp -- "${generated_output}/LinuxLoader.efi.cap" "${build_output}/"
    fi

    cix_radxa_remove_workspace "${firmware_source}" "${build_output}"
    cix_log "Radxa Orion ${platform} firmware build complete"
)
