#!/bin/bash
# medo_start.sh — main pod startup orchestrator
# Called by start_wrapper.sh after Docker-level setup.
# No set -euo pipefail — too risky with third-party scripts

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Resolve a single canonical ComfyUI path to avoid startup inconsistency
resolve_comfyui_dir() {
    if [[ -n "${COMFYUI_DIR:-}" ]] && [[ -d "${COMFYUI_DIR}" ]]; then
        echo "${COMFYUI_DIR}"
        return 0
    fi
    if [[ -d "/workspace/ComfyUI" ]]; then
        echo "/workspace/ComfyUI"
        return 0
    fi
    if [[ -d "/workspace/runpod-slim/ComfyUI" ]]; then
        echo "/workspace/runpod-slim/ComfyUI"
        return 0
    fi
    return 1
}

log "Pod started"

# ─── HuggingFace cache → network volume (must be first, before any HF download) ──
export HF_HOME="/workspace/.cache/huggingface"
export HF_DATASETS_CACHE="/workspace/.cache/huggingface/datasets"
export TRANSFORMERS_CACHE="/workspace/.cache/huggingface/hub"
mkdir -p "${HF_HOME}"
log "HF_HOME → ${HF_HOME}"

# ─── System tools ─────────────────────────────────────────────────────────────
DEBIAN_FRONTEND=noninteractive apt-get update -qq && \
    apt-get install -y --no-install-recommends nano aria2

# ─── SSH ──────────────────────────────────────────────────────────────────────
if [[ -n "${PUBLIC_KEY:-}" ]]; then
    mkdir -p ~/.ssh
    chmod 700 ~/.ssh
    echo "$PUBLIC_KEY" >> ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
    service ssh start && log "SSH started" || log "SSH failed"
fi

# ─── Workspace mounts ─────────────────────────────────────────────────────────
/comfyui-on-workspace.sh    || log "WARNING: comfyui-on-workspace.sh failed"
/ai-toolkit-on-workspace.sh || log "WARNING: ai-toolkit-on-workspace.sh failed"

if RESOLVED_COMFYUI_DIR="$(resolve_comfyui_dir)"; then
    export COMFYUI_DIR="${RESOLVED_COMFYUI_DIR}"
    log "COMFYUI_DIR resolved → ${COMFYUI_DIR}"

    # Keep legacy location compatible while enforcing one canonical source
    if [[ "${COMFYUI_DIR}" == "/workspace/ComfyUI" ]] \
        && [[ -d "/workspace/runpod-slim" ]] \
        && [[ ! -e "/workspace/runpod-slim/ComfyUI" ]]; then
        ln -s /workspace/ComfyUI /workspace/runpod-slim/ComfyUI \
            && log "Linked /workspace/runpod-slim/ComfyUI → /workspace/ComfyUI" \
            || log "WARNING: failed to create compatibility symlink"
    fi
else
    log "ERROR: no ComfyUI directory found in expected locations"
fi

# ─── HuggingFace login ────────────────────────────────────────────────────────
if [[ -n "${HF_TOKEN:-}" ]] && [[ "${HF_TOKEN}" != "enter_your_huggingface_token_here" ]]; then
    log "Logging into HuggingFace..."
    hf auth login --token "${HF_TOKEN}" || log "WARNING: HF login failed"
else
    log "HF_TOKEN not set, skipping"
fi

# ─── mediapipe / controlnet_aux compatibility ─────────────────────────────────
if ! /opt/venv/bin/python -c "import mediapipe as mp; assert hasattr(mp, 'solutions')" >/dev/null 2>&1; then
    log "Pinning mediapipe==0.10.11 (mp.solutions missing)"
    /opt/venv/bin/python -m pip install --no-cache-dir "mediapipe==0.10.11" \
        && log "mediapipe pinned OK" \
        || log "WARNING: mediapipe pin failed"
else
    log "mediapipe OK"
fi

# ─── comfy-aimdo (VRAM on-demand offloader) ───────────────────────────────────
AIMDO_DIR="/workspace/comfy-aimdo"

if ! /opt/venv/bin/python -c "import comfy_aimdo" >/dev/null 2>&1; then
    if [[ ! -d "${AIMDO_DIR}" ]]; then
        log "Cloning comfy-aimdo..."
        git clone https://github.com/Comfy-Org/comfy-aimdo "${AIMDO_DIR}" \
            && log "comfy-aimdo cloned" || log "WARNING: comfy-aimdo clone failed"
    fi

    if [[ -d "${AIMDO_DIR}" ]]; then
        log "Building & installing comfy-aimdo..."
        /opt/venv/bin/pip install "${AIMDO_DIR}" \
            && log "comfy-aimdo installed OK" \
            || log "WARNING: comfy-aimdo install failed (CUDA/PyTorch version mismatch?)"
    fi
else
    log "comfy-aimdo already installed, skipping"
fi

# ─── ComfyUI frontend version patch ───────────────────────────────────────────
/opt/venv/bin/pip install -q "comfyui-frontend-package>=1.41.21" \
    && log "comfyui-frontend-package patched" \
    || log "WARNING: frontend patch failed"

# ─── AI-Toolkit UI ────────────────────────────────────────────────────────────
if [[ -d "/workspace/ai-toolkit/ui" ]]; then
    log "Starting AI-Toolkit UI on port 8675"
    cd /workspace/ai-toolkit/ui
    if [[ -d .next && -f dist/worker.js ]]; then
        nohup npm run start > /workspace/ai-toolkit/ui/server.log 2>&1 &
    else
        log "No prebuilt artifacts — running build_and_start (slow)"
        nohup npm run build_and_start > /workspace/ai-toolkit/ui/server.log 2>&1 &
    fi
    cd - > /dev/null
else
    log "AI-Toolkit UI not found, skipping"
fi

# ─── Optional model downloads ─────────────────────────────────────────────────
[[ "${DOWNLOAD_WAN:-false}"  == "true" ]] && /download_wan2.1.sh  || true
[[ "${DOWNLOAD_FLUX:-false}" == "true" ]] && /download_Files.sh   || true

# ─── nginx ────────────────────────────────────────────────────────────────────
service nginx start && log "nginx started" || log "WARNING: nginx failed"

# ─── Flux model check ─────────────────────────────────────────────────────────
bash /check_files.sh || true

# ─── S3 offloader ─────────────────────────────────────────────────────────────
S3_OFFLOADER_DIR="/workspace/comfyui_S3_offloader"

if [[ ! -d "${S3_OFFLOADER_DIR}" ]]; then
    log "Cloning comfyui_S3_offloader..."
    git clone https://github.com/sinclairfr/comfyui_S3_offloader "${S3_OFFLOADER_DIR}" \
        && log "S3 offloader cloned" || log "WARNING: S3 offloader clone failed"
else
    log "comfyui_S3_offloader already present, pulling latest..."
    git -C "${S3_OFFLOADER_DIR}" pull || log "WARNING: S3 offloader pull failed"
fi

if [[ -f "${S3_OFFLOADER_DIR}/app.py" ]]; then
    if [[ -x "${S3_OFFLOADER_DIR}/.venv/bin/python" ]]; then
        S3_PY="${S3_OFFLOADER_DIR}/.venv/bin/python"
    elif [[ -x "/workspace/venv/bin/python" ]]; then
        S3_PY="/workspace/venv/bin/python"
    else
        S3_PY="python"
    fi
    log "S3 offloader using: ${S3_PY}"

    if ! "${S3_PY}" -c "import flask, boto3, dotenv" >/dev/null 2>&1; then
        log "Installing S3 offloader deps..."
        "${S3_PY}" -m pip install -r "${S3_OFFLOADER_DIR}/requirements.txt" || true
    fi

    nohup "${S3_PY}" "${S3_OFFLOADER_DIR}/app.py" \
        > "${S3_OFFLOADER_DIR}/app.log" 2>&1 &
    log "S3 offloader started (PID $!)"
else
    log "S3 offloader app.py not found, skipping"
fi

# ─── Filebrowser ──────────────────────────────────────────────────────────────
FILEBROWSER_VERSION="${FILEBROWSER_VERSION:-2.32.0}"

if ! command -v filebrowser &>/dev/null; then
    log "Installing filebrowser v${FILEBROWSER_VERSION}..."
    curl -fsSL \
        "https://github.com/filebrowser/filebrowser/releases/download/v${FILEBROWSER_VERSION}/linux-amd64-filebrowser.tar.gz" \
        | tar -xz -C /usr/local/bin filebrowser
    chmod +x /usr/local/bin/filebrowser
fi

nohup filebrowser \
    --address 0.0.0.0 \
    --port 8081 \
    --root /workspace \
    --noauth \
    --log /workspace/filebrowser.log >/dev/null 2>&1 &
log "Filebrowser started on port 8081 (PID $!)"

# ─── start_user.sh ────────────────────────────────────────────────────────────
log "Regenerating start_user.sh with canonical ComfyUI path resolution"
cat > /workspace/start_user.sh << 'EOF'
#!/bin/bash
# start_user.sh — ComfyUI launcher (generated by medo_start.sh)

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

resolve_comfyui_dir() {
    if [[ -n "${COMFYUI_DIR:-}" ]] && [[ -d "${COMFYUI_DIR}" ]]; then
        echo "${COMFYUI_DIR}"
        return 0
    fi
    if [[ -d "/workspace/ComfyUI" ]]; then
        echo "/workspace/ComfyUI"
        return 0
    fi
    if [[ -d "/workspace/runpod-slim/ComfyUI" ]]; then
        echo "/workspace/runpod-slim/ComfyUI"
        return 0
    fi
    return 1
}

COMFYUI_DIR="$(resolve_comfyui_dir)"
COMFYUI_PORT="${COMFYUI_PORT:-3000}"

if [[ ! -d "${COMFYUI_DIR}" ]]; then
    log "ERROR: ComfyUI not found at ${COMFYUI_DIR}"
    exit 1
fi

log "Starting ComfyUI on port ${COMFYUI_PORT}..."
cd "${COMFYUI_DIR}"
exec /opt/venv/bin/python main.py \
    --listen 0.0.0.0 \
    --port "${COMFYUI_PORT}" \
    --enable-cors-header
EOF
chmod +x /workspace/start_user.sh

log "Executing start_user.sh..."
bash /workspace/start_user.sh

log "All services up"
sleep infinity
