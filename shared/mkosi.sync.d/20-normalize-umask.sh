#!/bin/bash
set -euo pipefail
# chmod fails on Lima host mounts (virtiofs/reverse-sshfs) because the
# guest cannot change permissions on files owned by the macOS host.
# Allow failure so Lima-based builds still work; permissions are only
# needed for bit-for-bit reproducibility across different build envs.
# TODO: A more principled fix would be to rsync/copy the source tree to a
# VM-local directory before building (then chmod works and the build also
# avoids slow host-mount I/O). env_wrapper.sh would need to orchestrate this.
chmod -cR go-w "$SRCDIR" 2>/dev/null || echo "WARNING: chmod go-w failed on $SRCDIR (expected on Lima host mounts), continuing..."
