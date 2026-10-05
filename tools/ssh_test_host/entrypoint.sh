#!/usr/bin/env bash
# Starts sshd for the terminal tests.
#
# Host keys are generated on first start so the container can be recreated without
# changing the fingerprint the app has already trusted (they live in the volume mounted
# at /etc/ssh when one is provided).
set -euo pipefail

if [[ ! -f /etc/ssh/ssh_host_ed25519_key ]]; then
  ssh-keygen -A
fi

# Password auth is what the test configures by default; public key auth is on so the
# key-based path can be exercised with the same container.
cat >/etc/ssh/sshd_config.d/10-operit-test.conf <<'EOF'
PasswordAuthentication yes
KbdInteractiveAuthentication no
PermitRootLogin no
AllowTcpForwarding yes
GatewayPorts yes
X11Forwarding no
EOF

mkdir -p /run/sshd

exec /usr/sbin/sshd -D -e
