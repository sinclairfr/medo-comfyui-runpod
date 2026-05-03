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

# ─── Self-update: if we're the baked-in copy, try to fetch a fresh version ────
if [[ "${BASH_SOURCE[0]}" == "/medo_start.sh" ]]; then
  log "Pod started (baked-in — attempting self-update...)"
  _SELF_URL="https://raw.githubusercontent.com/${MEDO_REPO:-sinclairfr/medo-comfyui-runpod}/${MEDO_BRANCH:-main}/medo_start.sh"
  if curl -fsSL --max-time 30 --retry 3 --retry-delay 2 \
      "${_SELF_URL}" -o /tmp/medo_start.sh 2>/tmp/medo_curl.err \
      && [[ -s /tmp/medo_start.sh ]]; then
    chmod +x /tmp/medo_start.sh
    log "Self-update OK — re-execing live version..."
    exec /tmp/medo_start.sh
  else
    log "Self-update failed: $(cat /tmp/medo_curl.err 2>/dev/null) — continuing with baked-in"
  fi
else
  log "Pod started (live from GitHub)"
fi

# ─── HuggingFace cache → network volume ───────────────────────────────────────
export HF_HOME="/workspace/.cache/huggingface"
export HF_DATASETS_CACHE="/workspace/.cache/huggingface/datasets"
export TRANSFORMERS_CACHE="/workspace/.cache/huggingface/hub"
mkdir -p "${HF_HOME}"
log "HF_HOME → ${HF_HOME}"

# ─── HuggingFace login ────────────────────────────────────────────────────────
if [[ -n "${HF_TOKEN:-}" ]] && [[ "${HF_TOKEN}" != "enter_your_huggingface_token_here" ]]; then
    log "Logging into HuggingFace..."
    hf auth login --token "${HF_TOKEN}" 2>&1 \
        | grep -E "^(Login|Token is valid|WARNING)" \
        || log "WARNING: HF login failed"
else
    log "HF_TOKEN not set, skipping"
fi

# ─── ComfyUI venv patches (only after first boot, when venv exists) ───────────
COMFYUI_PY="$(find_comfyui_python)"
if [[ "${COMFYUI_PY}" != "python3" ]]; then
    log "ComfyUI venv: ${COMFYUI_PY}"

    # ─── PyTorch / CUDA driver compatibility fix ──────────────────────────────
    # If the host machine's NVIDIA driver is older than what cu128 needs (≥ 570),
    # detect the actual CUDA version and reinstall a compatible PyTorch build.
    if ! "${COMFYUI_PY}" -c "import torch; assert torch.cuda.is_available()" >/dev/null 2>&1; then
        log "CUDA not available — checking driver version..."

        # nvidia-smi reports "CUDA Version: 12.4" → we compute 12*1000+4*10 = 12040
        CUDA_INT=$(nvidia-smi 2>/dev/null \
            | grep -oP 'CUDA Version: \K[\d.]+' \
            | awk -F. '{print $1*1000 + $2*10}' \
            | head -1)

        log "CUDA driver integer: ${CUDA_INT:-unknown}"

        if [[ -n "${CUDA_INT}" ]] && [[ "${CUDA_INT}" -gt 0 ]] && [[ "${CUDA_INT}" -lt 12080 ]]; then
            if   [[ "${CUDA_INT}" -ge 12060 ]]; then TORCH_CU="cu126"
            elif [[ "${CUDA_INT}" -ge 12040 ]]; then TORCH_CU="cu124"
            elif [[ "${CUDA_INT}" -ge 12010 ]]; then TORCH_CU="cu121"
            else
                log "WARNING: CUDA driver too old (${CUDA_INT}) — cannot install compatible PyTorch"
                TORCH_CU=""
            fi

            if [[ -n "${TORCH_CU}" ]]; then
                log "Installing PyTorch ${TORCH_CU} (driver supports CUDA ${CUDA_INT})..."
                "${COMFYUI_PY}" -m pip install -q --no-cache-dir \
                    torch torchvision torchaudio \
                    --index-url "https://download.pytorch.org/whl/${TORCH_CU}" \
                    && log "PyTorch ${TORCH_CU} installed OK" \
                    || log "WARNING: PyTorch ${TORCH_CU} install failed"
            fi
        else
            log "WARNING: CUDA unavailable but driver version unknown or ≥ 12.8 — skipping PyTorch fix"
        fi
    else
        log "CUDA OK"
    fi

    # mediapipe — install quietly, only if not already at correct version
    if ! "${COMFYUI_PY}" -c "import mediapipe; assert mediapipe.__version__ >= '0.10.13'" >/dev/null 2>&1; then
        log "Installing mediapipe>=0.10.13..."
        "${COMFYUI_PY}" -m pip install -q --no-cache-dir "mediapipe>=0.10.13" \
            && log "mediapipe OK" || log "WARNING: mediapipe install failed"
    else
        log "mediapipe OK"
    fi

    # comfy-aimdo (VRAM on-demand offloader)
    AIMDO_DIR="/workspace/comfy-aimdo"
    if ! "${COMFYUI_PY}" -c "import comfy_aimdo" >/dev/null 2>&1; then
        if [[ ! -d "${AIMDO_DIR}" ]]; then
            log "Cloning comfy-aimdo..."
            git clone https://github.com/Comfy-Org/comfy-aimdo "${AIMDO_DIR}" \
                && log "comfy-aimdo cloned" || log "WARNING: comfy-aimdo clone failed"
        fi
        if [[ -d "${AIMDO_DIR}" ]]; then
            log "Installing comfy-aimdo..."
            "${COMFYUI_PY}" -m pip install -q "${AIMDO_DIR}" \
                && log "comfy-aimdo installed OK" \
                || log "WARNING: comfy-aimdo install failed"
        fi
    else
        log "comfy-aimdo OK"
    fi

    # ComfyUI frontend version patch
    if ! "${COMFYUI_PY}" -c "
import comfyui_frontend_package as f
from packaging.version import Version
assert Version(f.__version__) >= Version('1.41.21')
" >/dev/null 2>&1; then
        log "Patching comfyui-frontend-package..."
        "${COMFYUI_PY}" -m pip install -q "comfyui-frontend-package>=1.41.21" \
            && log "comfyui-frontend-package patched" \
            || log "WARNING: frontend patch failed"
    else
        log "comfyui-frontend-package OK"
    fi

    # Custom node missing deps: sox → qwen3-tts, wget → comfyui_layerstyle
    if ! "${COMFYUI_PY}" -c "import sox, wget" >/dev/null 2>&1; then
        log "Installing custom node deps (sox, wget)..."
        "${COMFYUI_PY}" -m pip install -q --no-cache-dir sox wget \
            && log "sox + wget OK" || log "WARNING: sox/wget install failed"
    else
        log "sox + wget OK"
    fi

    # llama-cpp-python → AILab_QwenVL_GGUF (best-effort)
    if ! "${COMFYUI_PY}" -c "import llama_cpp" >/dev/null 2>&1; then
        log "Installing llama-cpp-python..."
        "${COMFYUI_PY}" -m pip install -q --no-cache-dir llama-cpp-python \
            --extra-index-url https://abetlen.github.io/llama-cpp-python/whl/cu128 \
            && log "llama-cpp-python OK" \
            || log "WARNING: llama-cpp-python install failed (non-critical)"
    else
        log "llama-cpp-python OK"
    fi
else
    log "ComfyUI venv not found yet (first boot) — skipping venv patches"
fi

# ─── Optional model downloads ─────────────────────────────────────────────────
[[ "${DOWNLOAD_WAN:-false}"  == "true" ]] && [[ -x /download_wan2.1.sh ]] && /download_wan2.1.sh  || true
[[ "${DOWNLOAD_FLUX:-false}" == "true" ]] && [[ -x /download_Files.sh  ]] && /download_Files.sh   || true

# ─── S3 offloader ─────────────────────────────────────────────────────────────
S3_OFFLOADER_DIR="/workspace/comfyui_S3_offloader"

if [[ ! -d "${S3_OFFLOADER_DIR}" ]]; then
    log "Cloning comfyui_S3_offloader..."
    git clone https://github.com/sinclairfr/comfyui_S3_offloader "${S3_OFFLOADER_DIR}" \
        && log "S3 offloader cloned" || log "WARNING: S3 offloader clone failed"
else
    log "S3 offloader present, pulling latest..."
    git -C "${S3_OFFLOADER_DIR}" remote set-url origin \
        "https://github.com/sinclairfr/comfyui_S3_offloader"
    git -C "${S3_OFFLOADER_DIR}" pull 2>&1 | tail -1 \
        || log "WARNING: S3 offloader pull failed"
fi

if [[ -f "${S3_OFFLOADER_DIR}/app.py" ]]; then
    nohup python3 "${S3_OFFLOADER_DIR}/app.py" > "${S3_OFFLOADER_DIR}/app.log" 2>&1 &
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
    --database /workspace/.filebrowser.db \
    --noauth \
    >> /workspace/filebrowser.log 2>&1 &
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

# ─── Pre-flight: kill stale ComfyUI processes + release SQLite locks ──────────
# Handles the case where a previous ComfyUI crashed and left the db locked.
if pkill -0 -f "python.*main\.py" 2>/dev/null; then
    log "Killing stale ComfyUI process(es)..."
    pkill -f "python.*main\.py" 2>/dev/null
    sleep 1
fi
# Safe to remove WAL/SHM after killing all writers — SQLite will rebuild them.
rm -f /workspace/ComfyUI/user/comfyui.db-wal \
      /workspace/ComfyUI/user/comfyui.db-shm

# ─── Hand off to RunPod's /start.sh (sets up venv + launches ComfyUI) ─────────
log "Handing off to /start.sh..."
exec /start.sh
