#!/bin/bash
# medo_start.sh — pod startup orchestrator for runpod/comfyui base image
# Called by start_wrapper.sh. Runs extra services then hands off to /start.sh.

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Find the ComfyUI Python venv (exists only after first /start.sh boot).
# Falls back to system python3 (used for S3 offloader, whose deps are in the image).
find_comfyui_python() {
    for py in \
        /workspace/runpod-slim/ComfyUI/.venv-cu128/bin/python \
        /workspace/ComfyUI/.venv-cu128/bin/python; do
        [[ -x "$py" ]] && echo "$py" && return 0
    done
    echo "python3"
}

log "Pod started"

# ─── HuggingFace cache → network volume ───────────────────────────────────────
export HF_HOME="/workspace/.cache/huggingface"
export HF_DATASETS_CACHE="/workspace/.cache/huggingface/datasets"
export TRANSFORMERS_CACHE="/workspace/.cache/huggingface/hub"
mkdir -p "${HF_HOME}"
log "HF_HOME → ${HF_HOME}"

# ─── HuggingFace login ────────────────────────────────────────────────────────
if [[ -n "${HF_TOKEN:-}" ]] && [[ "${HF_TOKEN}" != "enter_your_huggingface_token_here" ]]; then
    log "Logging into HuggingFace..."
    hf auth login --token "${HF_TOKEN}" 2>&1 | grep -v "^$" || log "WARNING: HF login failed"
else
    log "HF_TOKEN not set, skipping"
fi

# ─── mediapipe / controlnet_aux compatibility ─────────────────────────────────
# Only runs on subsequent boots once the ComfyUI venv exists.
COMFYUI_PY="$(find_comfyui_python)"
if [[ "${COMFYUI_PY}" != "python3" ]]; then
    if ! "${COMFYUI_PY}" -c "import mediapipe as mp; assert hasattr(mp, 'solutions')" >/dev/null 2>&1; then
        log "Pinning mediapipe==0.10.11..."
        "${COMFYUI_PY}" -m pip install --no-cache-dir "mediapipe==0.10.11" \
            && log "mediapipe pinned OK" || log "WARNING: mediapipe pin failed"
    else
        log "mediapipe OK"
    fi

    # ─── comfy-aimdo (VRAM on-demand offloader) ───────────────────────────────
    AIMDO_DIR="/workspace/comfy-aimdo"
    if ! "${COMFYUI_PY}" -c "import comfy_aimdo" >/dev/null 2>&1; then
        if [[ ! -d "${AIMDO_DIR}" ]]; then
            log "Cloning comfy-aimdo..."
            git clone https://github.com/Comfy-Org/comfy-aimdo "${AIMDO_DIR}" \
                && log "comfy-aimdo cloned" || log "WARNING: comfy-aimdo clone failed"
        fi
        if [[ -d "${AIMDO_DIR}" ]]; then
            log "Installing comfy-aimdo..."
            "${COMFYUI_PY}" -m pip install "${AIMDO_DIR}" \
                && log "comfy-aimdo installed OK" \
                || log "WARNING: comfy-aimdo install failed"
        fi
    else
        log "comfy-aimdo already installed, skipping"
    fi

    # ─── ComfyUI frontend version patch ───────────────────────────────────────
    "${COMFYUI_PY}" -m pip install -q "comfyui-frontend-package>=1.41.21" \
        && log "comfyui-frontend-package patched" \
        || log "WARNING: frontend patch failed"
else
    log "ComfyUI venv not found yet (first boot) — skipping mediapipe/aimdo/frontend patches"
fi

# ─── Optional model downloads ─────────────────────────────────────────────────
[[ "${DOWNLOAD_WAN:-false}"  == "true" ]] && [[ -x /download_wan2.1.sh ]]  && /download_wan2.1.sh  || true
[[ "${DOWNLOAD_FLUX:-false}" == "true" ]] && [[ -x /download_Files.sh ]]   && /download_Files.sh   || true

# ─── S3 offloader ─────────────────────────────────────────────────────────────
# flask/boto3/python-dotenv are pre-installed in the image (Dockerfile pip install).
S3_OFFLOADER_DIR="/workspace/comfyui_S3_offloader"

if [[ ! -d "${S3_OFFLOADER_DIR}" ]]; then
    log "Cloning comfyui_S3_offloader..."
    git clone https://github.com/sinclairfr/comfyui_S3_offloader "${S3_OFFLOADER_DIR}" \
        && log "S3 offloader cloned" || log "WARNING: S3 offloader clone failed"
else
    log "comfyui_S3_offloader present, pulling latest..."
    git -C "${S3_OFFLOADER_DIR}" pull 2>&1 || log "WARNING: S3 offloader pull failed"
fi

if [[ -f "${S3_OFFLOADER_DIR}/app.py" ]]; then
    nohup python3 "${S3_OFFLOADER_DIR}/app.py" \
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
        | tar -xz -C /usr/local/bin filebrowser \
        && chmod +x /usr/local/bin/filebrowser
fi

nohup filebrowser \
    --address 0.0.0.0 \
    --port 8081 \
    --root /workspace \
    --noauth \
    --log /workspace/filebrowser.log >/dev/null 2>&1 &
log "Filebrowser started on port 8081 (PID $!)"

# ─── AI-Toolkit UI ────────────────────────────────────────────────────────────
if [[ -d "/workspace/ai-toolkit/ui" ]]; then
    log "Starting AI-Toolkit UI on port 8675..."
    cd /workspace/ai-toolkit/ui
    if [[ -d .next && -f dist/worker.js ]]; then
        nohup npm run start > /workspace/ai-toolkit/ui/server.log 2>&1 &
    else
        log "No prebuilt artifacts — running build_and_start (slow)"
        nohup npm run build_and_start > /workspace/ai-toolkit/ui/server.log 2>&1 &
    fi
    cd - > /dev/null
else
    log "AI-Toolkit UI not found at /workspace/ai-toolkit/ui, skipping"
fi

# ─── Hand off to RunPod's /start.sh (sets up venv + launches ComfyUI) ─────────
log "Handing off to /start.sh..."
exec /start.sh
