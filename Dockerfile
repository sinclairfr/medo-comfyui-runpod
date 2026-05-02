# Pin to a specific digest for reproducible builds.
# To update: docker pull runpod/comfyui:latest && docker inspect --format='{{index .RepoDigests 0}}' runpod/comfyui:latest
FROM runpod/comfyui:latest

# ---------------------------------------------------------------------------
# Timezone
# ---------------------------------------------------------------------------
ENV TZ=Europe/Paris

# ---------------------------------------------------------------------------
# System tools — the stuff you always need when SSHed into a pod
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    # timezone
    tzdata \
    # editors
    nano \
    vim \
    # process / network inspection
    lsof \
    iproute2 \
    net-tools \
    iputils-ping \
    procps \
    # file tools
    tree \
    jq \
    unzip \
    zip \
    rsync \
    pv \
    # build essentials
    git \
    curl \
    wget \
    ca-certificates \
    build-essential \
    # misc
    htop \
    tmux \
    screen \
    less \
    && ln -snf /usr/share/zoneinfo/Europe/Paris /etc/localtime \
    && echo Europe/Paris > /etc/timezone \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# uv — fast pip replacement, needed by ComfyUI-Manager at prestartup
# ---------------------------------------------------------------------------
RUN pip install --no-cache-dir uv

# ---------------------------------------------------------------------------
# Node.js 20 (required for ai-toolkit UI)
# ---------------------------------------------------------------------------
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
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

# Isolated Python venv for ai-toolkit
RUN python3 -m venv /opt/ai-toolkit-venv

# torch 2.7.0 — first version with cu128 wheels
RUN /opt/ai-toolkit-venv/bin/pip install --no-cache-dir \
    torch==2.7.0 torchvision==0.22.0 torchaudio==2.7.0 \
    --index-url https://download.pytorch.org/whl/cu128

# ai-toolkit Python requirements + gradio
RUN /opt/ai-toolkit-venv/bin/pip install --no-cache-dir \
    -r /opt/ai-toolkit/requirements.txt

RUN /opt/ai-toolkit-venv/bin/pip install --no-cache-dir --upgrade \
    accelerate transformers diffusers huggingface_hub gradio

# Build the Next.js UI
RUN cd /opt/ai-toolkit/ui \
    && npm install \
    && npx prisma generate \
    && npm run build

# ---------------------------------------------------------------------------
# Startup scripts
# ---------------------------------------------------------------------------
COPY start_wrapper.sh /start_wrapper.sh
COPY medo_start.sh /medo_start.sh
RUN chmod +x /start_wrapper.sh /medo_start.sh

ENTRYPOINT ["/start_wrapper.sh"]
