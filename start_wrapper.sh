#!/bin/bash
# start_wrapper.sh — Docker ENTRYPOINT for comfyui-medo image
# Handles image-level setup, then hands off to medo_start.sh.

REVISION="${REVISION:-0}"
REVISION_DATE="${REVISION_DATE:-$(date +%d/%y)}"

log() { echo "[wrapper] $*"; }

print_header() {
  echo "========================================"
  echo "  comfyui-medo"
  echo "  revision: r${REVISION}"
  echo "  date: ${REVISION_DATE}"
  echo "========================================"
}

# ---------------------------------------------------------------------------
# SSH — host keys + authorized key + optional GitHub deploy key
# ---------------------------------------------------------------------------
setup_ssh() {
  mkdir -p ~/.ssh
  [ ! -f /etc/ssh/ssh_host_ed25519_key ] && ssh-keygen -A -q

  if [[ -n "${PUBLIC_KEY:-}" ]]; then
    grep -qxF "$PUBLIC_KEY" ~/.ssh/authorized_keys 2>/dev/null \
      || echo "$PUBLIC_KEY" >> ~/.ssh/authorized_keys
    chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys
    log "SSH: public key installed"
  else
    RANDOM_PASS=$(openssl rand -base64 12)
    echo "root:${RANDOM_PASS}" | chpasswd
    log "SSH: random root password: ${RANDOM_PASS}"
  fi

  if [[ -n "${SSH_PRIVATE_KEY:-}" ]]; then
    echo "$SSH_PRIVATE_KEY" | base64 -d > ~/.ssh/id_ed25519
    chmod 600 ~/.ssh/id_ed25519
    ssh-keyscan -t ed25519 github.com >> ~/.ssh/known_hosts 2>/dev/null
    if ! grep -q "Host github.com" ~/.ssh/config 2>/dev/null; then
      cat >> ~/.ssh/config << 'EOF'
Host github.com
  HostName github.com
  User git
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
EOF
      chmod 600 ~/.ssh/config
    fi
    log "SSH: private key + GitHub host configured"
  fi

  grep -q "^PermitUserEnvironment yes" /etc/ssh/sshd_config \
    || echo "PermitUserEnvironment yes" >> /etc/ssh/sshd_config
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

print_header
setup_ssh

log "Handing off to /medo_start.sh..."
exec /medo_start.sh
