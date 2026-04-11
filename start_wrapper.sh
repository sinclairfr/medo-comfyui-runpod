#!/bin/bash
# start_wrapper.sh — ENTRYPOINT for comfyui-medo image
# Runs before /start.sh (the runpod/comfyui base entrypoint).
# All sections are idempotent — safe on pod restarts.

# ---------------------------------------------------------------------------
# Config — override via RunPod env vars
# ---------------------------------------------------------------------------
COMFYUI_VENV="/workspace/runpod-slim/ComfyUI/.venv-cu128"
S3_OFFLOADER_DIR="/workspace/comfyui_S3_offloader"
S3_OFFLOADER_REPO="https://github.com/sinclairfr/comfyui_S3_offloader"
AI_TOOLKIT_DIR="/workspace/ai-toolkit"
RUN_AI_TOOLKIT="${RUN_AI_TOOLKIT:-false}"   # set to true/1/yes in RunPod env vars

log() { echo "[wrapper] $*"; }

# ---------------------------------------------------------------------------
# SSH: install PUBLIC_KEY if provided, else generate a random password
# ---------------------------------------------------------------------------
setup_ssh() {
  mkdir -p ~/.ssh

  [ ! -f /etc/ssh/ssh_host_ed25519_key ] && ssh-keygen -A -q

  if [[ -n "${PUBLIC_KEY:-}" ]]; then
    grep -qxF "$PUBLIC_KEY" ~/.ssh/authorized_keys 2>/dev/null \
      || echo "$PUBLIC_KEY" >> ~/.ssh/authorized_keys
    chmod 700 ~/.ssh
    chmod 600 ~/.ssh/authorized_keys
    log "SSH: public key installed from PUBLIC_KEY env var"
  else
    RANDOM_PASS=$(openssl rand -base64 12)
    echo "root:${RANDOM_PASS}" | chpasswd
    log "SSH: no PUBLIC_KEY set — random root password: ${RANDOM_PASS}"
  fi

  grep -q "^PermitUserEnvironment yes" /etc/ssh/sshd_config \
    || echo "PermitUserEnvironment yes" >> /etc/ssh/sshd_config
}

# ---------------------------------------------------------------------------
# GitHub SSH: restore private key from GITHUB_SSH_KEY (base64-encoded)
# How to encode your key: base64 -w0 ~/.ssh/id_ed25519
# ---------------------------------------------------------------------------
setup_github_ssh() {
  if [[ -z "${GITHUB_SSH_KEY:-}" ]]; then
    log "GitHub SSH: GITHUB_SSH_KEY not set, skipping"
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

  log "GitHub SSH: key configured (~/.ssh/github_key)"
}

# ---------------------------------------------------------------------------
# Patch /start.sh: disable Jupyter
# ---------------------------------------------------------------------------
patch_base_start() {
  chmod +x /start.sh

  sed -i \
    -e 's/^\s*start_jupyter\s*$/true/' \
    -e 's/^\s*start_jupyter\.sh\s*$/true/' \
    /start.sh

  if grep -qE '^\s*start_jupyter' /start.sh; then
    log "WARNING: Jupyter patch may have failed — check /start.sh manually"
  else
    log "Jupyter disabled in /start.sh"
  fi
}

# ---------------------------------------------------------------------------
# S3 offloader: clone if missing, then launch
# Deps are pre-installed at image build time (see Dockerfile)
# ---------------------------------------------------------------------------
start_s3_offloader() {
  if [[ ! -d "${S3_OFFLOADER_DIR}" ]]; then
    log "S3 offloader: cloning..."
    git clone "${S3_OFFLOADER_REPO}" "${S3_OFFLOADER_DIR}" \
      && log "S3 offloader: cloned OK" \
      || { log "S3 offloader: clone FAILED — skipping"; return; }
  else
    log "S3 offloader: already present, skipping clone"
  fi

  [[ ! -f "${S3_OFFLOADER_DIR}/app.py" ]] && { log "S3 offloader: app.py not found — skipping"; return; }

  cd "${S3_OFFLOADER_DIR}"
  nohup python3 app.py >> /workspace/s3_offloader.log 2>&1 &
  log "S3 offloader: started (PID $!), logs → /workspace/s3_offloader.log"
  cd - >/dev/null
}

# ---------------------------------------------------------------------------
# ai-toolkit: launch if RUN_AI_TOOLKIT is truthy
# Entry point: flux_train_ui.py
# ---------------------------------------------------------------------------
start_ai_toolkit() {
  if [[ ! -d "${AI_TOOLKIT_DIR}" ]]; then
    log "ai-toolkit: ${AI_TOOLKIT_DIR} not found — clone it to your volume first"
    return
  fi

  # Pick Python — prefer ai-toolkit's own venv, fall back to ComfyUI venv
  if [[ -x "${AI_TOOLKIT_DIR}/.venv/bin/python" ]]; then
    ATK_PY="${AI_TOOLKIT_DIR}/.venv/bin/python"
  elif [[ -x "${AI_TOOLKIT_DIR}/venv/bin/python" ]]; then
    ATK_PY="${AI_TOOLKIT_DIR}/venv/bin/python"
  elif [[ -x "${COMFYUI_VENV}/bin/python" ]]; then
    ATK_PY="${COMFYUI_VENV}/bin/python"
    log "ai-toolkit: no dedicated venv, falling back to ComfyUI venv"
  else
    ATK_PY="python3"
    log "ai-toolkit: no venv found, using system python3"
  fi

  # Known entry points in priority order
  for candidate in \
    "${AI_TOOLKIT_DIR}/flux_train_ui.py" \
    "${AI_TOOLKIT_DIR}/run_gradio.py" \
    "${AI_TOOLKIT_DIR}/toolkit/ui/app.py"
  do
    if [[ -f "$candidate" ]]; then
      ATK_ENTRY="$candidate"
      break
    fi
  done

  if [[ -z "${ATK_ENTRY:-}" ]]; then
    log "ai-toolkit: no known entry point found — skipping"
    return
  fi

  log "ai-toolkit: starting $(basename ${ATK_ENTRY}) with ${ATK_PY}..."
  cd "${AI_TOOLKIT_DIR}"
  nohup "${ATK_PY}" "${ATK_ENTRY}" >> "${AI_TOOLKIT_DIR}/server.log" 2>&1 &
  log "ai-toolkit: started (PID $!), logs → ${AI_TOOLKIT_DIR}/server.log"
  cd - >/dev/null
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

setup_ssh
setup_github_ssh
patch_base_start
start_s3_offloader

case "${RUN_AI_TOOLKIT,,}" in
  true|1|yes) start_ai_toolkit ;;
  *) log "ai-toolkit: disabled (RUN_AI_TOOLKIT=${RUN_AI_TOOLKIT})" ;;
esac

# Expose ComfyUI venv to PATH so ComfyUI-Manager finds pip at prestartup
export PATH="${COMFYUI_VENV}/bin:$PATH"

log "Handing off to /start.sh..."
exec /start.sh
