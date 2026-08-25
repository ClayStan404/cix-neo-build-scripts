#!/usr/bin/env bash
# Collect a read-only O6 PM/CPU state snapshot for before/after comparison.
set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage: sudo collect-o6-pm-state.sh PMTOOL OUTPUT_DIR

PMTOOL must be the manifest-pinned ARM64 pmtool executable. OUTPUT_DIR must not
already exist. The script reads firmware and Linux state; it does not change PM
configuration, CPU policy, firmware, or kernel settings.
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

[[ "${1:-}" != "-h" && "${1:-}" != "--help" ]] || {
    usage
    exit 0
}
(($# == 2)) || {
    usage >&2
    exit 2
}
((EUID == 0)) || die "run this read-only collector as root"

pmtool="$1"
output_dir="$2"
[[ -x "${pmtool}" ]] || die "pmtool is missing or not executable: ${pmtool}"
[[ ! -e "${output_dir}" ]] || die "output directory already exists: ${output_dir}"

mkdir -p -- "${output_dir}"

{
    printf 'captured_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'hostname=%s\n' "$(hostname)"
    printf 'kernel=%s\n' "$(uname -srvm)"
    printf 'architecture=%s\n' "$(uname -m)"
    if [[ -r /etc/os-release ]]; then
        sed -n 's/^\(ID\|VERSION_ID\|PRETTY_NAME\)=/os_\1=/p' /etc/os-release
    fi
} >"${output_dir}/system.txt"

sha256sum -- "${pmtool}" >"${output_dir}/pmtool.sha256"
"${pmtool}" cli opp_config >"${output_dir}/pmtool-opp-config.txt" 2>&1

if command -v lscpu >/dev/null 2>&1; then
    lscpu >"${output_dir}/lscpu.txt"
fi
if command -v dmidecode >/dev/null 2>&1; then
    dmidecode --type bios >"${output_dir}/bios.txt" 2>&1 || true
fi

{
    shopt -s nullglob
    policies=(/sys/devices/system/cpu/cpufreq/policy*)
    for policy in "${policies[@]}"; do
        printf '[%s]\n' "${policy##*/}"
        for field in \
            affected_cpus cpuinfo_cur_freq cpuinfo_max_freq cpuinfo_min_freq \
            scaling_available_frequencies scaling_available_governors \
            scaling_cur_freq scaling_driver scaling_governor scaling_max_freq \
            scaling_min_freq; do
            if [[ -r "${policy}/${field}" ]]; then
                printf '%s=' "${field}"
                tr '\n' ' ' <"${policy}/${field}"
                printf '\n'
            fi
        done
    done
} >"${output_dir}/cpufreq.txt"

{
    shopt -s nullglob
    zones=(/sys/class/thermal/thermal_zone*)
    for zone in "${zones[@]}"; do
        printf '[%s]\n' "${zone##*/}"
        [[ ! -r "${zone}/type" ]] || printf 'type=%s\n' "$(<"${zone}/type")"
        [[ ! -r "${zone}/temp" ]] || printf 'temp_millicelsius=%s\n' "$(<"${zone}/temp")"
    done
} >"${output_dir}/thermal.txt"

dmesg >"${output_dir}/dmesg.txt" 2>&1 || true
grep -Ei 'scmi|thermal|regulator|cpufreq|opp|voltage|pm firmware' \
    "${output_dir}/dmesg.txt" >"${output_dir}/dmesg-pm.txt" || true

(
    cd "${output_dir}"
    files=(*)
    sha256sum -- "${files[@]}" >SHA256SUMS
)

printf 'O6 PM state captured in %s\n' "${output_dir}"
