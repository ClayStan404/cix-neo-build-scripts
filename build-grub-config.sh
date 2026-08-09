#!/usr/bin/env bash
# Build the CIX GRUB configuration package.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

export CIX_NATIVE_TARGET="grub-config"
export CIX_NATIVE_PACKAGING_REL="debian/grub-config"
export CIX_NATIVE_LABEL="GRUB configuration"

exec "${SCRIPT_DIR}/build-native-package.sh" "$@"
