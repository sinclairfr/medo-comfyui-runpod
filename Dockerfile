# Pin to a specific digest for reproducible builds.
# To update: docker pull runpod/comfyui:latest && docker inspect --format='{{index .RepoDigests 0}}' runpod/comfyui:latest
FROM runpod/comfyui:latest

# ---------------------------------------------------------------------------
# System deps + Node.js 20 (required for ai-toolkit UI)
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    ca-certificates \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# S3 offloader deps
# ---------------------------------------------------------------------------
RUN pip install --no-cache-dir flask boto3 python-dotenv

# ---------------------------------------------------------------------------
# ComfyUI custom node deps
# ---------------------------------------------------------------------------
RUN pip install --no-cache-dir \
    gguf \
    scikit-image \
    ultralytics \
    dill \
    piexif \
    segment-anything \
    albumentations \
    imageio-ffmpeg

# ---------------------------------------------------------------------------
# ai-toolkit — cloned into /opt/ai-toolkit
# ---------------------------------------------------------------------------
RUN git clone --depth=1 https://github.com/ostris/ai-toolkit.git /opt/ai-toolkit \
    && cd /opt/ai-toolkit \
    && git submodule update --init --recursive

# Isolated Python venv — no system-site-packages to avoid version conflicts
RUN python3 -m venv /opt/ai-toolkit-venv

# torch 2.7.0 is the first version with cu128 wheels on PyTorch CDN
RUN /opt/ai-toolkit-venv/bin/pip install --no-cache-dir \
    torch==2.7.0 torchvision==0.22.0 torchaudio==2.7.0 \
    --index-url https://download.pytorch.org/whl/cu128

# ai-toolkit Python requirements
RUN /opt/ai-toolkit-venv/bin/pip install --no-cache-dir \
    -r /opt/ai-toolkit/requirements.txt

# Upgrade key packages for compatibility
RUN /opt/ai-toolkit-venv/bin/pip install --no-cache-dir --upgrade \
    accelerate transformers diffusers huggingface_hub

# Build the Node.js UI (output: ui/dist/)
RUN cd /opt/ai-toolkit/ui && npm install && npm run build

# ---------------------------------------------------------------------------
# Wrapper
# ---------------------------------------------------------------------------
COPY start_wrapper.sh /start_wrapper.sh
RUN chmod +x /start_wrapper.sh

ENTRYPOINT ["/start_wrapper.sh"]
