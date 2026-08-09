#!/usr/bin/env bash
# Build the CIX NPU DKMS source package.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

export CIX_DKMS_TARGET="npu-dkms"
export CIX_DKMS_SOURCE_REL="sources/npu-driver/driver"
export CIX_DKMS_GIT_REL="sources/npu-driver"
export CIX_DKMS_PACKAGING_REL="debian/npu-dkms"
export CIX_DKMS_LABEL="NPU"

exec "${SCRIPT_DIR}/build-dkms-package.sh" "$@"
