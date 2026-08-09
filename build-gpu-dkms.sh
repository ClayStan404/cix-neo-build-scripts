#!/usr/bin/env bash
# Build the CIX GPU DKMS source package.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

export CIX_DKMS_TARGET="gpu-dkms"
export CIX_DKMS_SOURCE_REL="sources/gpu-kernel"
export CIX_DKMS_GIT_REL="sources/gpu-kernel"
export CIX_DKMS_PACKAGING_REL="debian/gpu-dkms"
export CIX_DKMS_LABEL="GPU"

exec "${SCRIPT_DIR}/build-dkms-package.sh" "$@"
