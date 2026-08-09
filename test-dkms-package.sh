#!/usr/bin/env bash
# Build a packaged CIX DKMS module against packaged CIX kernel headers.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=framework.sh
source "${SCRIPT_DIR}/framework.sh"

: "${CIX_DKMS_TEST_TARGET:?CIX_DKMS_TEST_TARGET is required}"
: "${CIX_DKMS_TEST_BINARY:?CIX_DKMS_TEST_BINARY is required}"
: "${CIX_DKMS_TEST_ARTIFACT_GLOB:?CIX_DKMS_TEST_ARTIFACT_GLOB is required}"
: "${CIX_DKMS_TEST_LABEL:?CIX_DKMS_TEST_LABEL is required}"

jobs="${CIX_BUILD_JOBS:-$(cix_default_jobs)}"
kernel_headers_deb=""
dkms_deb=""
output_dir="${CIX_OUTPUT_DIR:-${CIX_WORKSPACE_ROOT}/output}/${CIX_DKMS_TEST_TARGET}/tests"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Build the modules shipped by ${CIX_DKMS_TEST_BINARY} against the headers
shipped by the CIX kernel build. All DKMS source, state, and module trees are
temporary; the host /usr/src, /var/lib/dkms, and /lib/modules trees are not
modified.

Options:
  --kernel-headers PATH  CIX linux-headers deb; auto-detected if unambiguous
  --package PATH         ${CIX_DKMS_TEST_LABEL} DKMS deb; auto-detected if unambiguous
  --jobs COUNT           Parallel DKMS build jobs
  --output-dir PATH      Directory for the retained DKMS make log
  -h, --help             Show this help
EOF
}

while (($#)); do
    case "$1" in
        --kernel-headers)
            (($# >= 2)) || cix_die "$1 requires a value"
            kernel_headers_deb="$2"
            shift 2
            ;;
        --package|--gpu-package|--vpu-package|--npu-package)
            (($# >= 2)) || cix_die "$1 requires a value"
            dkms_deb="$2"
            shift 2
            ;;
        --jobs)
            (($# >= 2)) || cix_die "$1 requires a value"
            jobs="$2"
            shift 2
            ;;
        --output-dir)
            (($# >= 2)) || cix_die "$1 requires a value"
            output_dir="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            cix_die "unknown argument: $1"
            ;;
    esac
done

select_single_artifact() {
    local directory="$1"
    local pattern="$2"
    local description="$3"
    local artifact
    local -a artifacts=()

    if [[ -d "${directory}" ]]; then
        while IFS= read -r -d '' artifact; do
            artifacts+=("${artifact}")
        done < <(find "${directory}" -maxdepth 1 -type f -name "${pattern}" -print0)
    fi

    ((${#artifacts[@]} == 1)) ||
        cix_die "expected exactly one ${description} in ${directory}; found ${#artifacts[@]}"
    printf '%s\n' "${artifacts[0]}"
}

cix_validate_debian_13_arm64
cix_validate_positive_integer "jobs" "${jobs}"
cix_require_command awk dpkg-deb find mktemp realpath sort uname

if command -v dkms >/dev/null; then
    dkms_command="$(command -v dkms)"
elif [[ -x /usr/sbin/dkms ]]; then
    dkms_command=/usr/sbin/dkms
else
    cix_die "dkms is unavailable; run ${SCRIPT_DIR}/setup-sbuild.sh first"
fi
readonly dkms_command

if command -v modinfo >/dev/null; then
    modinfo_command="$(command -v modinfo)"
elif [[ -x /usr/sbin/modinfo ]]; then
    modinfo_command=/usr/sbin/modinfo
else
    cix_die "modinfo is unavailable; run ${SCRIPT_DIR}/setup-sbuild.sh first"
fi
readonly modinfo_command

if [[ -z "${kernel_headers_deb}" ]]; then
    kernel_headers_deb="$(select_single_artifact \
        "${CIX_WORKSPACE_ROOT}/output/kernel" \
        'linux-headers-*_arm64.deb' 'CIX kernel headers package')"
fi
if [[ -z "${dkms_deb}" ]]; then
    dkms_deb="$(select_single_artifact \
        "${CIX_WORKSPACE_ROOT}/output/${CIX_DKMS_TEST_TARGET}/artifacts" \
        "${CIX_DKMS_TEST_ARTIFACT_GLOB}" "${CIX_DKMS_TEST_LABEL} DKMS package")"
fi

kernel_headers_deb="$(realpath -e -- "${kernel_headers_deb}")"
dkms_deb="$(realpath -e -- "${dkms_deb}")"
output_dir="$(realpath -m -- "${output_dir}")"
readonly kernel_headers_deb dkms_deb output_dir

header_package="$(dpkg-deb -f "${kernel_headers_deb}" Package)"
header_architecture="$(dpkg-deb -f "${kernel_headers_deb}" Architecture)"
binary_package="$(dpkg-deb -f "${dkms_deb}" Package)"
binary_architecture="$(dpkg-deb -f "${dkms_deb}" Architecture)"

[[ "${header_package}" == linux-headers-* ]] ||
    cix_die "not a Linux headers package: ${header_package}"
kernel_release="${header_package#linux-headers-}"
[[ "${kernel_release}" == *-cix-build || "${kernel_release}" == *-cix-build-* ]] ||
    cix_die "kernel headers are not from a CIX build: ${kernel_release}"
[[ "${header_architecture}" == "arm64" ]] ||
    cix_die "CIX kernel headers must be arm64: ${header_architecture}"
[[ "${binary_package}" == "${CIX_DKMS_TEST_BINARY}" ]] ||
    cix_die "unexpected ${CIX_DKMS_TEST_LABEL} package: ${binary_package}"
[[ "${binary_architecture}" == "all" ]] ||
    cix_die "${CIX_DKMS_TEST_LABEL} DKMS package must be architecture all: ${binary_architecture}"

kernel_architecture="$(uname -m)"
[[ "${kernel_architecture}" == "aarch64" ]] ||
    cix_die "DKMS kernel architecture must be aarch64: ${kernel_architecture}"

mkdir -p -- "${output_dir}"
work_root="$(mktemp -d "${output_dir}/.dkms-test.XXXXXXXXXX")"
package_root="${work_root}/root"
dkms_tree="${work_root}/dkms"
source_tree="${package_root}/usr/src"
install_tree="${package_root}/lib/modules"
build_log_source=""
result_log=""

cleanup() {
    local exit_status=$?

    trap - EXIT
    if [[ -n "${build_log_source}" && -f "${build_log_source}" && -n "${result_log}" ]]; then
        if ! cp -- "${build_log_source}" "${result_log}"; then
            cix_log "Failed to retain DKMS build log: ${result_log}"
            ((exit_status != 0)) || exit_status=1
        fi
    fi
    if [[ -d "${work_root}" ]]; then
        rm -rf -- "${work_root}"
    fi
    exit "${exit_status}"
}
trap cleanup EXIT

mkdir -p -- "${package_root}" "${dkms_tree}" "${install_tree}"
cix_log "Extract CIX kernel headers: ${kernel_headers_deb}"
dpkg-deb -x "${kernel_headers_deb}" "${package_root}"
cix_log "Extract ${CIX_DKMS_TEST_LABEL} DKMS package: ${dkms_deb}"
dpkg-deb -x "${dkms_deb}" "${package_root}"

header_dir="${source_tree}/${header_package}"
[[ -f "${header_dir}/.config" && -f "${header_dir}/Module.symvers" ]] ||
    cix_die "CIX kernel headers are incomplete: ${header_dir}"

mapfile -d '' -t module_configs < <(
    find "${source_tree}" -mindepth 2 -maxdepth 2 -type f -name dkms.conf -print0
)
((${#module_configs[@]} == 1)) ||
    cix_die "expected exactly one packaged dkms.conf; found ${#module_configs[@]}"
module_config="${module_configs[0]}"
module_name="$(awk -F '"' '/^PACKAGE_NAME="[^"]+"$/ { print $2; exit }' "${module_config}")"
module_version="$(awk -F '"' '/^PACKAGE_VERSION="[^"]+"$/ { print $2; exit }' "${module_config}")"
mapfile -t expected_modules < <(
    awk -F '"' '/^BUILT_MODULE_NAME\[[0-9]+\]="[^"]+"$/ { print $2 }' \
        "${module_config}" | sort -u
)

[[ -n "${module_name}" && -n "${module_version}" ]] ||
    cix_die "packaged dkms.conf has no module name or version"
((${#expected_modules[@]} > 0)) ||
    cix_die "packaged dkms.conf declares no built modules"

result_stem="${module_name}_${module_version}_${kernel_release}"
result_stem="${result_stem//:/_}"
result_log="${output_dir}/${result_stem}.log"
build_log_source="${dkms_tree}/${module_name}/${module_version}/build/make.log"

common_dkms_args=(
    --dkmstree "${dkms_tree}"
    --sourcetree "${source_tree}"
    --installtree "${install_tree}"
)

cix_log "Register ${module_name}/${module_version} in the isolated DKMS tree"
"${dkms_command}" add \
    -m "${module_name}" \
    -v "${module_version}" \
    "${common_dkms_args[@]}"

cix_log "Build ${CIX_DKMS_TEST_LABEL} modules for CIX kernel ${kernel_release}"
"${dkms_command}" build \
    -m "${module_name}" \
    -v "${module_version}" \
    -k "${kernel_release}" \
    -a "${kernel_architecture}" \
    --kernelsourcedir "${header_dir}" \
    --no-depmod \
    -j "${jobs}" \
    "${common_dkms_args[@]}"

build_log_source="${dkms_tree}/${module_name}/${module_version}/${kernel_release}/${kernel_architecture}/log/make.log"
[[ -f "${build_log_source}" ]] || cix_die "DKMS build log is missing: ${build_log_source}"
module_root="${dkms_tree}/${module_name}/${module_version}/${kernel_release}/${kernel_architecture}/module"
for expected_module in "${expected_modules[@]}"; do
    module_file="${module_root}/${expected_module}.ko"
    [[ -s "${module_file}" ]] || cix_die "DKMS did not build ${expected_module}.ko"
    vermagic="$("${modinfo_command}" -F vermagic "${module_file}")"
    [[ "${vermagic%% *}" == "${kernel_release}" ]] ||
        cix_die "${expected_module}.ko targets unexpected kernel: ${vermagic}"
    printf '    %s (%s)\n' "${module_file}" "${vermagic}"
done

"${dkms_command}" status "${common_dkms_args[@]}"
cix_log "${CIX_DKMS_TEST_LABEL} DKMS compatibility test passed; build log: ${result_log}"
