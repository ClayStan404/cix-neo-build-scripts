#!/usr/bin/env bash
# Test the CIX GPU DKMS package against packaged CIX kernel headers.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

export CIX_DKMS_TEST_TARGET="gpu-dkms"
export CIX_DKMS_TEST_BINARY="cix-gpu-dkms"
export CIX_DKMS_TEST_ARTIFACT_GLOB="cix-gpu-dkms_*_all.deb"
export CIX_DKMS_TEST_LABEL="GPU"

exec "${SCRIPT_DIR}/test-dkms-package.sh" "$@"
