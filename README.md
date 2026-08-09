# Build System

This directory will contain the new configuration-driven build orchestration
and module implementations. It must not depend on the legacy build-system CLI
or framework contract.

The initial modules are the Linux kernel and GPU DKMS package.

## sbuild Environment

Run the setup script as a regular user with sudo access:

```bash
./build-scripts/setup-sbuild.sh
```

The script installs missing host prerequisites, validates native ARM64 user
namespace support, provisions dedicated temporary and ccache directories, and
creates an sbuild unshare tarball with `mmdebstrap`.

Use `--help` to see distribution, mirror, tarball, and rebuild overrides.
