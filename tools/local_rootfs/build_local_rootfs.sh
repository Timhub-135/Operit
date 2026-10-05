#!/usr/bin/env bash
# Rebuilds the bundled local Ubuntu rootfs with openssh-client preinstalled.
#
# Runs inside a privileged ubuntu container: the rootfs is an arm64 userland, so apt has
# to execute through qemu-user-static. The point of the rebuild is that the local target
# is usable without the user running `apt install ssh` after installation.
#
# Environment:
#   IN_NAME   input asset name under terminal/src/main/assets
#   OUT_NAME  output asset name (keep the ubuntu-noble-aarch64 prefix: the app derives
#             the installed distro name from the file name)
#   WORK      scratch directory, defaults to /work
#   REPO      repository mount point, defaults to /repo
set -euo pipefail

IN_NAME="${IN_NAME:?IN_NAME is required}"
OUT_NAME="${OUT_NAME:?OUT_NAME is required}"
WORK="${WORK:-/work}"
REPO="${REPO:-/repo}"

ASSET_DIR="$REPO/terminal/src/main/assets"
ROOTFS_TOP="ubuntu-noble-aarch64"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates xz-utils qemu-user-static
rm -rf /var/lib/apt/lists/*

rm -rf "$WORK/rootfs"
mkdir -p "$WORK/rootfs"
tar -xJf "$ASSET_DIR/$IN_NAME" -C "$WORK/rootfs"

ROOT="$WORK/rootfs/$ROOTFS_TOP"
test -d "$ROOT" || { echo "unexpected archive layout: $ROOT missing" >&2; exit 1; }

# Install inside the arm64 userland through qemu.
cp "$(command -v qemu-aarch64-static)" "$ROOT/usr/bin/qemu-aarch64-static"

# The bundled image addresses the Aliyun ports mirror; ubuntu-ports is the arm64 archive.
mkdir -p "$ROOT/etc/apt"
cat >"$ROOT/etc/apt/sources.list" <<'EOF'
deb https://mirrors.aliyun.com/ubuntu-ports/ noble main restricted universe multiverse
deb https://mirrors.aliyun.com/ubuntu-ports/ noble-updates main restricted universe multiverse
deb https://mirrors.aliyun.com/ubuntu-ports/ noble-backports main restricted universe multiverse
deb https://mirrors.aliyun.com/ubuntu-ports/ noble-security main restricted universe multiverse
EOF
rm -f "$ROOT/etc/apt/sources.list.d/ubuntu.sources" "$ROOT/etc/apt/sources.list.d/"*.list 2>/dev/null || true

RESOLV_BACKUP=""
if [ -e "$ROOT/etc/resolv.conf" ] || [ -L "$ROOT/etc/resolv.conf" ]; then
  cp -a "$ROOT/etc/resolv.conf" "$WORK/resolv.conf.bak"
  RESOLV_BACKUP="$WORK/resolv.conf.bak"
fi
cp /etc/resolv.conf "$ROOT/etc/resolv.conf"

chroot "$ROOT" /usr/bin/env DEBIAN_FRONTEND=noninteractive /bin/bash -c '
  set -euo pipefail
  apt-get update
  apt-get install -y --no-install-recommends openssh-client
  # Drop the downloaded package lists again: the asset is shipped inside the APK.
  apt-get clean
  rm -rf /var/lib/apt/lists/*
'

if [ -n "$RESOLV_BACKUP" ]; then
  cp -a "$RESOLV_BACKUP" "$ROOT/etc/resolv.conf"
else
  rm -f "$ROOT/etc/resolv.conf"
fi

rm -f "$ROOT/usr/bin/qemu-aarch64-static"

# Acceptance: the ssh client has to be present and runnable inside the image.
chroot "$ROOT" /usr/bin/ssh -V

cd "$WORK/rootfs"
tar -cJf "$ASSET_DIR/$OUT_NAME" "$ROOTFS_TOP"
ls -l "$ASSET_DIR/$OUT_NAME"
