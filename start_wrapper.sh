#!/bin/bash
# start_wrapper.sh — ENTRYPOINT for comfyui-medo image
# All sections are idempotent — safe on pod restarts.

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
COMFYUI_VENV="/workspace/runpod-slim/ComfyUI/.venv-cu128"
S3_OFFLOADER_DIR="/workspace/comfyui_S3_offloader"
S3_OFFLOADER_REPO="https://github.com/sinclairfr/comfyui_S3_offloader"

ATK_CODE="/opt/ai-toolkit"
ATK_VENV="/opt/ai-toolkit-venv"
ATK_WORKSPACE="/workspace/ai-toolkit"
RUN_AI_TOOLKIT="${RUN_AI_TOOLKIT:-false}"

log() { echo "[wrapper] $*"; }

# ---------------------------------------------------------------------------
# SSH
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

  grep -q "^PermitUserEnvironment yes" /etc/ssh/sshd_config \
    || echo "PermitUserEnvironment yes" >> /etc/ssh/sshd_config
}

# ---------------------------------------------------------------------------
# GitHub SSH
# ---------------------------------------------------------------------------
setup_github_ssh() {
  if [[ -z "${GITHUB_SSH_KEY:-}" ]]; then
    log "GitHub SSH: not set, skipping"
    return
  fi

  mkdir -p ~/.ssh
  echo "$GITHUB_SSH_KEY" | base64 -d > ~/.ssh/github_key
  chmod 600 ~/.ssh/github_key
  ssh-keyscan -t ed25519 github.com >> ~/.ssh/known_hosts 2>/dev/null

  if ! grep -q "Host github.com" ~/.ssh/config 2>/dev/null; then
    cat >> ~/.ssh/config << 'EOF'
Host github.com
  HostName github.com
  User git
  IdentityFile ~/.ssh/github_key
  IdentitiesOnly yes
EOF
    chmod 600 ~/.ssh/config
  fi
  log "GitHub SSH: configured"
}

# ---------------------------------------------------------------------------
# S3 offloader
# ---------------------------------------------------------------------------
start_s3_offloader() {
  if [[ ! -d "${S3_OFFLOADER_DIR}" ]]; then
    log "S3 offloader: cloning..."
    git clone "${S3_OFFLOADER_REPO}" "${S3_OFFLOADER_DIR}" \
      && log "S3 offloader: cloned OK" \
      || { log "S3 offloader: clone FAILED — skipping"; return; }
  fi

  [[ ! -f "${S3_OFFLOADER_DIR}/app.py" ]] \
    && { log "S3 offloader: app.py not found — skipping"; return; }

  cd "${S3_OFFLOADER_DIR}"
  nohup python3 app.py >> /workspace/s3_offloader.log 2>&1 &
  log "S3 offloader: started (PID $!)"
  cd - >/dev/null
}

# ---------------------------------------------------------------------------
# ai-toolkit
# Code at /opt/ai-toolkit (baked in image)
# User data (configs, datasets, output) on volume at /workspace/ai-toolkit
# Workspace dirs are symlinked into the code tree so the UI finds them
# ---------------------------------------------------------------------------
start_ai_toolkit() {
  if [[ ! -d "${ATK_CODE}" ]]; then
    log "ai-toolkit: /opt/ai-toolkit missing — image build issue"
    return
  fi

  # Set up workspace dirs on the persistent volume and symlink into code tree
  for dir in config datasets output jobs; do
    mkdir -p "${ATK_WORKSPACE}/${dir}"
    if [[ ! -e "${ATK_CODE}/${dir}" ]]; then
      ln -s "${ATK_WORKSPACE}/${dir}" "${ATK_CODE}/${dir}"
    elif [[ ! -L "${ATK_CODE}/${dir}" ]]; then
      mv "${ATK_CODE}/${dir}" "${ATK_CODE}/${dir}.bak"
      ln -s "${ATK_WORKSPACE}/${dir}" "${ATK_CODE}/${dir}"
    fi
  done

  # Point ai-toolkit to its own Python venv via env var
  export AI_TOOLKIT_PYTHON="${ATK_VENV}/bin/python"

  # Launch the Node.js UI server (port 8675)
  log "ai-toolkit: starting UI on port 8675..."
  cd "${ATK_CODE}"
  nohup node ui/dist/server/entry.mjs \
    >> "${ATK_WORKSPACE}/server.log" 2>&1 &
  log "ai-toolkit: UI started (PID $!), logs → ${ATK_WORKSPACE}/server.log"
  cd - >/dev/null
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

setup_ssh
setup_github_ssh
start_s3_offloader

case "${RUN_AI_TOOLKIT,,}" in
  true|1|yes) start_ai_toolkit ;;
  *) log "ai-toolkit: disabled (RUN_AI_TOOLKIT=${RUN_AI_TOOLKIT})" ;;
esac

# Expose ComfyUI venv so ComfyUI-Manager finds pip at prestartup
export PATH="${COMFYUI_VENV}/bin:$PATH"

log "Handing off to /start.sh..."
exec /start.sh
