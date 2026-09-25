# Qwen 2.1 — tailormade for abenzerps/Qwen-Image-2.1-Uncensored-GGUF
# Base: nvidia/cuda:12.6.3-cudnn-runtime-ubuntu24.04 (driver >=560, compat with 535+ hosts, unlike 12.8 needing 570)
ARG BASE_IMAGE=nvidia/cuda:12.6.3-cudnn-runtime-ubuntu24.04

# Stage 1: Base image with common dependencies
FROM ${BASE_IMAGE} AS base

# Qwen 2.1 requires ComfyUI >=0.3.44 (QWEN_IMAGE + QwenImage21 nodes) + diffusers>=0.37 + transformers>=5.17
ARG COMFYUI_VERSION=0.3.48
ARG CUDA_VERSION_FOR_COMFY=12.6
ARG ENABLE_PYTORCH_UPGRADE=true
ARG PYTORCH_INDEX_URL=https://download.pytorch.org/whl/cu126

ENV DEBIAN_FRONTEND=noninteractive
ENV PIP_PREFER_BINARY=1
ENV PYTHONUNBUFFERED=1
ENV CMAKE_BUILD_PARALLEL_LEVEL=8

# Install Python, git and other necessary tools (retry apt for transient mirror failures)
# build-essential + gcc + python3.12-dev needed for Triton JIT (comfy/text_encoders/qwen_image21 -> triton.language)
RUN (apt-get update || (sleep 5 && apt-get update) || (sleep 10 && apt-get update)) && apt-get install -y --fix-missing \
    python3.12 \
    python3.12-venv \
    python3.12-dev \
    git \
    wget \
    curl \
    libgl1 \
    libglib2.0-0 \
    libsm6 \
    libxext6 \
    libxrender1 \
    ffmpeg \
    openssh-server \
    build-essential \
    gcc \
    g++ \
    && ln -sf /usr/bin/python3.12 /usr/bin/python \
    && ln -sf /usr/bin/pip3 /usr/bin/pip

# Triton JIT needs a C compiler at RUNTIME (comfy/text_encoders/qwen_image21 -> triton.language).
# build-essential is not enough unless CC/CXX are exported and triton can find them on PATH.
ENV CC=gcc
ENV CXX=g++
ENV TRITON_CACHE_DIR=/tmp/triton_cache

# Clean up (keep gcc/g++ for runtime JIT)
RUN apt-get autoremove -y && apt-get clean -y && rm -rf /var/lib/apt/lists/* && \
    which gcc && gcc --version | head -1 && which g++ && g++ --version | head -1 && echo "C compiler OK (CC=$CC)" && \
    mkdir -p $TRITON_CACHE_DIR && chmod 777 $TRITON_CACHE_DIR

# Install uv (latest) using official installer and create isolated venv
RUN wget -qO- https://astral.sh/uv/install.sh | sh \
    && ln -s /root/.local/bin/uv /usr/local/bin/uv \
    && ln -s /root/.local/bin/uvx /usr/local/bin/uvx \
    && uv venv /opt/venv

ENV PATH="/opt/venv/bin:${PATH}"

# Install comfy-cli + dependencies needed by it to install ComfyUI
RUN uv pip install comfy-cli==1.13.0 pip setuptools wheel

# Install ComfyUI
RUN if [ -n "${CUDA_VERSION_FOR_COMFY}" ]; then \
      /usr/bin/yes | comfy --workspace /comfyui install --version "${COMFYUI_VERSION}" --cuda-version "${CUDA_VERSION_FOR_COMFY}" --nvidia; \
    else \
      /usr/bin/yes | comfy --workspace /comfyui install --version "${COMFYUI_VERSION}" --nvidia; \
    fi

# Ensure qwen_image21 support (Qwen 2.1 DiT + Qwen3-VL-8B). ComfyUI 0.3.48 should include it, but verify.
RUN if [ ! -f /comfyui/comfy/text_encoders/qwen_image21.py ]; then \
      echo "ComfyUI missing qwen_image21 - attempting to update (best effort)" && \
      (cd /comfyui && git init 2>&1 | head -3; git remote add origin https://github.com/comfyanonymous/ComfyUI 2>&1 | head -3; git fetch origin --depth=1 2>&1 | head -10; git checkout FETCH_HEAD -- comfy/text_encoders/qwen_image21.py 2>&1 | head -20; ls -l comfy/text_encoders/qwen_image*.py) || \
      echo "WARN: qwen_image21 still missing - bump COMFYUI_VERSION" && ls -l /comfyui/comfy/text_encoders/ 2>&1 | head -20; \
    else echo "ComfyUI qwen_image21 present:" && ls -l /comfyui/comfy/text_encoders/qwen_image*.py; fi

# Upgrade PyTorch if needed
RUN if [ "$ENABLE_PYTORCH_UPGRADE" = "true" ]; then \
      uv pip install --force-reinstall torch torchvision torchaudio --index-url ${PYTORCH_INDEX_URL}; \
    fi

# Mirror ComfyUI's full dependency set into /opt/venv so launch venv is complete (fixes "server not reachable").
# torch is pinned to cu126 first (matches BASE_IMAGE 12.6.3 / driver >=560). Then install ComfyUI reqs, then re-pin cu126.
# Then upgrade transformers/diffusers for Qwen 2.1. Triton must match torch — verify import.
RUN uv pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu126
RUN uv pip install -r /comfyui/requirements.txt
RUN for r in /comfyui/custom_nodes/*/requirements.txt; do [ -f "$r" ] && uv pip install -r "$r" || true; done
# Re-pin torch to cu126 after requirements.txt, then upgrade for Qwen 2.1 (transformers 5.x required for Qwen3-VL)
RUN uv pip install --upgrade torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu126 && \
    uv pip install --upgrade "transformers>=5.17,<6" "diffusers>=0.37.0" accelerate safetensors "huggingface-hub>=0.34" && \
    python -c "import torch; print('torch', torch.__version__, torch.version.cuda)" && \
    python -c "import triton; print('triton', triton.__version__)" && \
    python -c "import triton.language as tl; print('triton.language OK')" && \
    python -c "import diffusers; print('diffusers', diffusers.__version__)" && \
    python -c "import transformers; print('transformers', transformers.__version__)"

# ComfyUI-GGUF for UnetLoaderGGUF / CLIPLoaderGGUF
# HF docs: use leejet/ComfyUI-GGUF for Qwen 2.1 (native qwen_image21 arch). Prefer leejet, fallback to city96.
RUN uv pip install "gguf>=0.13.0" sentencepiece protobuf && \
    (git clone https://github.com/leejet/ComfyUI-GGUF /comfyui/custom_nodes/ComfyUI-GGUF && echo "Cloned leejet/ComfyUI-GGUF" || \
     (git clone https://github.com/city96/ComfyUI-GGUF /comfyui/custom_nodes/ComfyUI-GGUF && echo "Fallback city96")) && \
    uv pip install -r /comfyui/custom_nodes/ComfyUI-GGUF/requirements.txt || true && \
    ls -l /comfyui/custom_nodes/ComfyUI-GGUF/ && uv pip show gguf | head -5 && \
    PYTHONPATH=/comfyui python -c "import folder_paths; print('gguf loader check done')"

# Verify qwen_image21 arch is handled by GGUF loader (leejet should already support it; city96 needs patch)
RUN if grep -q "qwen_image21" /comfyui/custom_nodes/ComfyUI-GGUF/*.py 2>/dev/null; then \
      echo "GGUF qwen_image21 already supported (leejet)"; grep -l "qwen_image21" /comfyui/custom_nodes/ComfyUI-GGUF/*.py; \
    else \
      echo "Patching ComfyUI-GGUF for qwen_image21..."; grep -n "qwen_image" /comfyui/custom_nodes/ComfyUI-GGUF/*.py 2>&1 | head -20; \
      if grep -q '"qwen_image"' /comfyui/custom_nodes/ComfyUI-GGUF/loader.py 2>/dev/null; then \
        sed -i 's/"qwen_image"/"qwen_image", "qwen_image21"/' /comfyui/custom_nodes/ComfyUI-GGUF/loader.py && echo "Patched loader.py"; \
      fi; \
      grep -q "qwen_image21" /comfyui/custom_nodes/ComfyUI-GGUF/*.py && echo "Patch OK" || echo "WARN: qwen_image21 not found post-patch (may be OK with leejet)"; \
    fi

# Qwen 2.1 native nodes are in comfy/text_encoders/qwen_image21.py and comfy_extras/nodes_qwen.py (TextEncodeQwenImage21)
# Do NOT apply Phr00t Rapid-AIO patch (qwen-image-edit 1.x only) — it would overwrite native 2.1 nodes.

# Support for the network volume - copy BEFORE smoke test so yaml is validated at build time.
WORKDIR /comfyui
ADD src/extra_model_paths.yaml ./
RUN python -c "import yaml, pathlib; p=pathlib.Path('extra_model_paths.yaml'); cfg=yaml.safe_load(p.read_text()); assert 'runpod_worker_comfy' in cfg, cfg; assert 'unet_gguf' in cfg['runpod_worker_comfy'], 'unet_gguf missing'; assert 'clip_gguf' in cfg['runpod_worker_comfy'], 'clip_gguf missing'; print('extra_model_paths.yaml OK:', list(cfg['runpod_worker_comfy'].keys()))" \
 && python -c "import folder_paths, utils.extra_config; utils.extra_config.load_extra_path_config('extra_model_paths.yaml'); print('extra paths loaded, keys now:', [k for k in folder_paths.folder_names_and_paths if 'gguf' in k or k in ('diffusion_models','text_encoders')])"
WORKDIR /

# Build-time smoke test: actually start ComfyUI (imports full node graph incl. ComfyUI-GGUF + qwen_image21)
RUN cd /comfyui && timeout 300 python main.py --quick-test-for-ci --cpu
WORKDIR /comfyui
WORKDIR /

# Install Python runtime dependencies for the handler
RUN uv pip install runpod requests websocket-client

# Add application code and scripts
ADD src/start.sh src/network_volume.py handler.py test_input.json ./
RUN chmod +x /start.sh

COPY scripts/comfy-node-install.sh /usr/local/bin/comfy-node-install
RUN chmod +x /usr/local/bin/comfy-node-install
ENV PIP_NO_INPUT=1
COPY scripts/comfy-manager-set-mode.sh /usr/local/bin/comfy-manager-set-mode
RUN chmod +x /usr/local/bin/comfy-manager-set-mode

CMD ["/start.sh"]

# Stage 2: Download models
FROM base AS downloader
ARG HUGGINGFACE_ACCESS_TOKEN
ARG MODEL_TYPE=qwen-2.1
WORKDIR /comfyui
RUN mkdir -p models/checkpoints models/vae models/unet models/clip models/text_encoders models/diffusion_models models/model_patches models/loras

# Keep upstream MODEL_TYPE branches for compatibility, but qwen-2.1 is volume-native (see stage 3)
RUN if [ "$MODEL_TYPE" = "sdxl" ]; then \
      wget -q -O models/checkpoints/sd_xl_base_1.0.safetensors https://huggingface.co/stabilityai/stable-diffusion-xl-base-1.0/resolve/main/sd_xl_base_1.0.safetensors && \
      wget -q -O models/vae/sdxl_vae.safetensors https://huggingface.co/stabilityai/sdxl-vae/resolve/main/sdxl_vae.safetensors && \
      wget -q -O models/vae/sdxl-vae-fp16-fix.safetensors https://huggingface.co/madebyollin/sdxl-vae-fp16-fix/resolve/main/sdxl_vae.safetensors; \
    fi
RUN if [ "$MODEL_TYPE" = "qwen-image" ]; then \
      mkdir -p models/diffusion_models models/text_encoders models/vae && \
      wget -q -O models/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors && \
      wget -q -O models/vae/qwen_image_vae.safetensors https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/vae/qwen_image_vae.safetensors && \
      wget -q -O models/diffusion_models/qwen_image_2512_fp8_e4m3fn.safetensors https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/diffusion_models/qwen_image_2512_fp8_e4m3fn.safetensors; \
    fi
RUN if [ "$MODEL_TYPE" = "qwen-image-edit" ]; then \
      mkdir -p models/vae models/loras && \
      wget -q -O models/vae/qwen_image_vae.safetensors https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/vae/qwen_image_vae.safetensors && \
      wget -q -O models/loras/qwen-anime-irl.safetensors https://huggingface.co/flymy-ai/qwen-image-anime-irl-lora/resolve/main/flymy_anime_irl.safetensors && \
      echo "downloader: VAE + anime LoRA ready" && ls -lh models/vae/ models/loras/; \
    fi

# Bake VAE stub for qwen-2.1 (tiny, always useful even when volume holds it)
RUN if [ "$MODEL_TYPE" = "qwen-2.1" ]; then \
      mkdir -p models/vae && \
      wget -q -O models/vae/qwen_image_2.1_vae_bf16.safetensors https://huggingface.co/Comfy-Org/Qwen-Image-2.1/resolve/main/vae/qwen_image_2.1_vae_bf16.safetensors && \
      ln -sf qwen_image_2.1_vae_bf16.safetensors models/vae/qwen_image_vae.safetensors && \
      echo "qwen-2.1 VAE baked:" && ls -lh models/vae/; \
    fi

ARG USE_NETWORK_VOLUME=true

# Stage 3: qwen-downloader - adds GGUFs on top of downloader when NOT volume-native
FROM downloader AS qwen-downloader
ARG HUGGINGFACE_ACCESS_TOKEN
ARG MODEL_TYPE=qwen-2.1
ARG USE_NETWORK_VOLUME
WORKDIR /comfyui
# qwen-image-edit baked path (kept for compatibility)
RUN if [ "$MODEL_TYPE" = "qwen-image-edit" ] && [ "$USE_NETWORK_VOLUME" != "true" ]; then \
      set -x && \
      curl -L --retry 5 --retry-delay 10 --progress-bar -o models/text_encoders/Qwen2.5-VL-7B-Instruct-q4_0.gguf https://huggingface.co/ChrisColeTech/qwen-image-edit-uncensored-GGUF/resolve/main/split/text_encoders/Qwen2.5-VL-7B-Instruct-q4_0.gguf && \
      curl -L --retry 5 --retry-delay 10 --progress-bar -o models/diffusion_models/qwen-image-edit-2511-uncensored-Q6_K.gguf https://huggingface.co/ChrisColeTech/qwen-image-edit-uncensored-GGUF/resolve/main/split/diffusion_models/qwen-image-edit-2511-uncensored-Q6_K.gguf && \
      curl -L --retry 5 --retry-delay 10 --progress-bar -o models/text_encoders/Qwen2.5-VL-7B-Instruct-mmproj-f16.gguf https://huggingface.co/ChrisColeTech/qwen-image-edit-uncensored-GGUF/resolve/main/split/text_encoders/Qwen2.5-VL-7B-Instruct-mmproj-f16.gguf; \
    elif [ "$MODEL_TYPE" = "qwen-image-edit" ]; then echo "FAST: qwen-image-edit volume-native (skip bake)"; fi
# qwen-2.1: volume-native by default; optionally bake if USE_NETWORK_VOLUME=false
RUN if [ "$MODEL_TYPE" = "qwen-2.1" ] && [ "$USE_NETWORK_VOLUME" != "true" ]; then \
      echo "WARN: BAKED qwen-2.1 bake requested - downloading ~10GB (UC-Q4_K_M + Heretic + VAE)"; \
      mkdir -p models/diffusion_models models/text_encoders && \
      curl -L --retry 5 --retry-delay 10 --progress-bar -o models/diffusion_models/qwen-image-2.1-UC-Q4_K_M.gguf https://huggingface.co/abenzerps/Qwen-Image-2.1-Uncensored-GGUF/resolve/main/qwen-image-2.1-UC-Q4_K_M.gguf && \
      ln -sf qwen-image-2.1-UC-Q4_K_M.gguf models/diffusion_models/qwen-image-2.1-uncensored-Q4_K_M.gguf && \
      curl -L --retry 5 --retry-delay 10 --progress-bar -o models/text_encoders/qwen3vl_8b_heretic-Q4_K_M.gguf https://huggingface.co/pottokao/Qwen-Image-2.1-Text-Encoder-Heretic-GGUF/resolve/main/qwen3vl_8b_heretic-Q4_K_M.gguf && \
      ln -sf qwen3vl_8b_heretic-Q4_K_M.gguf models/text_encoders/qwen-image-2.1-text-encoder-uncensored-Q4_K_M.gguf && \
      curl -L --retry 5 --retry-delay 10 --progress-bar -o models/text_encoders/mmproj-qwen3vl_8b_heretic-f16.gguf https://huggingface.co/pottokao/Qwen-Image-2.1-Text-Encoder-Heretic-GGUF/resolve/main/mmproj-qwen3vl_8b_heretic-f16.gguf && \
      ln -sf mmproj-qwen3vl_8b_heretic-f16.gguf models/text_encoders/qwen-image-2.1-text-encoder-uncensored-mmproj-f16.gguf && \
      ls -lh models/diffusion_models/ models/text_encoders/; \
    elif [ "$MODEL_TYPE" = "qwen-2.1" ]; then \
      echo "qwen-2.1 volume-native - GGUFs live on /runpod-volume (see setup_network_volume.sh). Baked VAE only."; ls -R models || true; \
    fi
FROM qwen-downloader AS final
RUN echo "=== FINAL (qwen-2.1 volume-native) ===" && ls -lh /comfyui/models/text_encoders/ /comfyui/models/diffusion_models/ /comfyui/models/vae/ 2>&1; du -sh /comfyui/models/* 2>&1; echo "ComfyUI-GGUF:" && ls -ld /comfyui/custom_nodes/ComfyUI-GGUF 2>&1; echo "PyTorch:" && uv run python -c "import torch; print(torch.__version__, torch.version.cuda)" 2>&1 | head -5
