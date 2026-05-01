#!/bin/bash
# start_wrapper.sh — ENTRYPOINT for comfyui-medo image
# All sections are idempotent — safe on pod restarts.

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
COMFYUI_VENV="/workspace/ComfyUI/.venv-cu128"
S3_OFFLOADER_DIR="/workspace/comfyui_S3_offloader"
S3_OFFLOADER_REPO="https://github.com/sinclairfr/comfyui_S3_offloader"

ATK_CODE="/opt/ai-toolkit"
ATK_VENV="/opt/ai-toolkit-venv"
ATK_WORKSPACE="/workspace/ai-toolkit"
ATK_DB="${ATK_WORKSPACE}/aitk_db.db"
RUN_AI_TOOLKIT="${RUN_AI_TOOLKIT:-false}"

log() { echo "[wrapper] $*"; }

# ---------------------------------------------------------------------------
# Ensure ComfyUI is at /workspace/ComfyUI (runtime: network volume may have old path)
# Moves the directory once if needed, then symlinks the old path back so
# nothing that still references it (e.g. hardcoded scripts) breaks.
# ---------------------------------------------------------------------------
ensure_comfyui_path() {
  # Already in the right place — nothing to do
  [ -d /workspace/ComfyUI ] && return

  for src in /workspace/runpod-slim/ComfyUI /workspace/runpod-slim/Comfyui; do
    [ -d "$src" ] || continue
    log "ComfyUI: moving $src → /workspace/ComfyUI (one-time migration)..."
    mv "$src" /workspace/ComfyUI \
      && ln -s /workspace/ComfyUI "$src" \
      && log "ComfyUI: migration done, symlink left at $src" \
      || log "ComfyUI: migration FAILED — $src left in place"
    return
  done

  log "ComfyUI: WARNING — not found at old or new path, /start.sh will handle it"
}

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
# ai-toolkit UI (Next.js, port 8675)
# ---------------------------------------------------------------------------
start_ai_toolkit() {
  if [[ ! -d "${ATK_CODE}" ]]; then
    log "ai-toolkit: /opt/ai-toolkit missing — image build issue"
    return
  fi

  if [[ ! -d "${ATK_CODE}/ui/.next" ]]; then
    log "ai-toolkit: ui/.next not found — Next.js build may have failed"
    return
  fi

  mkdir -p "${ATK_WORKSPACE}"
  for dir in config datasets output jobs; do
    mkdir -p "${ATK_WORKSPACE}/${dir}"
    if [[ ! -e "${ATK_CODE}/${dir}" ]]; then
      ln -s "${ATK_WORKSPACE}/${dir}" "${ATK_CODE}/${dir}"
    elif [[ ! -L "${ATK_CODE}/${dir}" ]]; then
      mv "${ATK_CODE}/${dir}" "${ATK_CODE}/${dir}.bak"
      ln -s "${ATK_WORKSPACE}/${dir}" "${ATK_CODE}/${dir}"
    fi
  done

  export DATABASE_URL="file:${ATK_DB}"
  export AI_TOOLKIT_PYTHON="${ATK_VENV}/bin/python"

  # Init DB on first run
  if [[ ! -f "${ATK_DB}" ]]; then
    log "ai-toolkit: initializing Prisma DB..."
    cd "${ATK_CODE}/ui"
    DATABASE_URL="file:${ATK_DB}" npx prisma db push --skip-generate 2>&1 \
      | grep -E "(sync|error|Error)" || true
    cd - >/dev/null
  fi

  log "ai-toolkit: starting cron worker..."
  cd "${ATK_CODE}/ui"
  nohup node dist/cron/worker.js \
    >> "${ATK_WORKSPACE}/worker.log" 2>&1 &
  log "ai-toolkit: worker started (PID $!)"

  log "ai-toolkit: starting Next.js UI on port 8675..."
  nohup node_modules/.bin/next start --port 8675 \
    >> "${ATK_WORKSPACE}/server.log" 2>&1 &
  log "ai-toolkit: UI started (PID $!), logs → ${ATK_WORKSPACE}/server.log"
  cd - >/dev/null
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

ensure_comfyui_path
setup_ssh
start_s3_offloader

case "${RUN_AI_TOOLKIT,,}" in
  true|1|yes) start_ai_toolkit ;;
  *) log "ai-toolkit: disabled (RUN_AI_TOOLKIT=${RUN_AI_TOOLKIT})" ;;
esac

# Expose ComfyUI venv bin so ComfyUI-Manager finds pip at prestartup
export PATH="${COMFYUI_VENV}/bin:${PATH}"
echo "PATH=${COMFYUI_VENV}/bin:${PATH}" >> /etc/environment

log "Handing off to /start.sh..."
exec /start.sh
