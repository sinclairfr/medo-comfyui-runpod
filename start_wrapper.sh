#!/bin/bash
# start_wrapper.sh — ENTRYPOINT for comfyui-medo image
# Runs before /start.sh (the runpod/comfyui base entrypoint).
# All sections are idempotent — safe on pod restarts.

# ---------------------------------------------------------------------------
# Config — override via RunPod env vars
# ---------------------------------------------------------------------------
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

  # Generate host keys if missing (fresh container)
  [ ! -f /etc/ssh/ssh_host_ed25519_key ] && ssh-keygen -A -q

  if [[ -n "${PUBLIC_KEY:-}" ]]; then
    # Idempotent — don't append the same key twice on restarts
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

  # Trust github.com without interactive prompt
  ssh-keyscan -t ed25519 github.com >> ~/.ssh/known_hosts 2>/dev/null

  # Wire the key — idempotent block
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
# Patch /start.sh from the base image:
#   - disable Jupyter (we don't want it)
#   - verify the patch landed
# ---------------------------------------------------------------------------
patch_base_start() {
  chmod +x /start.sh

  # Disable Jupyter — sed replaces the bare call; handle both common variants
  sed -i \
    -e 's/^\s*start_jupyter\s*$/true/' \
    -e 's/^\s*start_jupyter\.sh\s*$/true/' \
    /start.sh

  # Verify the patch — warn loudly if Jupyter is still referenced
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
  # Clone repo if workspace doesn't have it yet
  if [[ ! -d "${S3_OFFLOADER_DIR}" ]]; then
    log "S3 offloader: cloning from ${S3_OFFLOADER_REPO}..."
    git clone "${S3_OFFLOADER_REPO}" "${S3_OFFLOADER_DIR}" \
      && log "S3 offloader: cloned OK" \
      || { log "S3 offloader: clone FAILED — skipping"; return; }
  else
    log "S3 offloader: already present, skipping clone"
  fi

  if [[ ! -f "${S3_OFFLOADER_DIR}/app.py" ]]; then
    log "S3 offloader: app.py not found after clone — skipping"
    return
  fi

  # deps are baked into the image; this is a safety net for new deps only
  if ! python3 -c "import flask, boto3, dotenv" >/dev/null 2>&1; then
    log "S3 offloader: installing missing deps..."
    pip install --no-cache-dir flask boto3 python-dotenv -q || true
  fi

  cd "${S3_OFFLOADER_DIR}"
  nohup python3 app.py >> /workspace/s3_offloader.log 2>&1 &
  log "S3 offloader: started (PID $!), logs → /workspace/s3_offloader.log"
  cd - >/dev/null
}

# ---------------------------------------------------------------------------
# ai-toolkit: launch if RUN_AI_TOOLKIT is truthy
# Expects ai-toolkit cloned at /workspace/ai-toolkit (persistent volume)
# ---------------------------------------------------------------------------
start_ai_toolkit() {
  if [[ ! -d "${AI_TOOLKIT_DIR}" ]]; then
    log "ai-toolkit: ${AI_TOOLKIT_DIR} not found — clone it to your volume first"
    return
  fi

  # Pick the right Python — prefer ai-toolkit's own venv
  if [[ -x "${AI_TOOLKIT_DIR}/.venv/bin/python" ]]; then
    ATK_PY="${AI_TOOLKIT_DIR}/.venv/bin/python"
  elif [[ -x "${AI_TOOLKIT_DIR}/venv/bin/python" ]]; then
    ATK_PY="${AI_TOOLKIT_DIR}/venv/bin/python"
  else
    ATK_PY="python3"
    log "ai-toolkit: no dedicated venv found, using system python3"
  fi

  # Detect entry point
  if [[ -f "${AI_TOOLKIT_DIR}/run_gradio.py" ]]; then
    ATK_ENTRY="run_gradio.py"
  elif [[ -f "${AI_TOOLKIT_DIR}/toolkit/ui/app.py" ]]; then
    ATK_ENTRY="toolkit/ui/app.py"
  else
    log "ai-toolkit: no known entry point found (run_gradio.py / toolkit/ui/app.py) — skipping"
    return
  fi

  log "ai-toolkit: starting ${ATK_ENTRY} on port 7860..."
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

# Launch ai-toolkit if requested — runs in background before handing off to /start.sh
case "${RUN_AI_TOOLKIT,,}" in
  true|1|yes)
    start_ai_toolkit
    ;;
  *)
    log "ai-toolkit: disabled (RUN_AI_TOOLKIT=${RUN_AI_TOOLKIT})"
    ;;
esac

log "Handing off to /start.sh..."
exec /start.sh
