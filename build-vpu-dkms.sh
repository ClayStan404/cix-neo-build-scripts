#!/usr/bin/env bash
# Build the CIX VPU DKMS source package.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

export CIX_DKMS_TARGET="vpu-dkms"
export CIX_DKMS_SOURCE_REL="sources/vpu-driver"
export CIX_DKMS_GIT_REL="sources/vpu-driver"
export CIX_DKMS_PACKAGING_REL="debian/vpu-dkms"
export CIX_DKMS_LABEL="VPU"

exec "${SCRIPT_DIR}/build-dkms-package.sh" "$@"
