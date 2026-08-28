# Generates real IaaS templates from .example files, injecting the local SSH public key.
set -euo pipefail

SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/id_ed25519.pub}"

if [ ! -f "$SSH_KEY_PATH" ]; then
  echo "SSH public key not found at $SSH_KEY_PATH (set SSH_KEY_PATH to override)"
  exit 1
fi

sed "s|REPLACE_WITH_YOUR_SSH_PUBLIC_KEY|$(cat "$SSH_KEY_PATH")|" \
  iaas/k3s-node.tmpl.example > iaas/k3s-node.tmpl

echo "Generated iaas/k3s-node.tmpl"