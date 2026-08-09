#!/usr/bin/env bash
# Test the CIX NPU DKMS package against packaged CIX kernel headers.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

export CIX_DKMS_TEST_TARGET="npu-dkms"
export CIX_DKMS_TEST_BINARY="cix-npu-driver-dkms"
export CIX_DKMS_TEST_ARTIFACT_GLOB="cix-npu-driver-dkms_*_all.deb"
export CIX_DKMS_TEST_LABEL="NPU"

exec "${SCRIPT_DIR}/test-dkms-package.sh" "$@"
