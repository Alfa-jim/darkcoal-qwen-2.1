# darkcoal-qwen-2.1

> Tailormade for **Qwen-Image 2.1** GGUF — fork of [darkcoal-qwen-fast](https://github.com/Alfa-jim/darkcoal-qwen-fast) for [abenzerps/Qwen-Image-2.1-Uncensored-GGUF](https://huggingface.co/abenzerps/Qwen-Image-2.1-Uncensored-GGUF) (DiT 7B UC GGUF) + [pottokao Heretic](https://huggingface.co/pottokao/Qwen-Image-2.1-Text-Encoder-Heretic-GGUF) Qwen3-VL text encoder. Unified T2I + image editing + native RGBA + up to 16 refs. Network-volume-native (`/runpod-volume`) for RunPod 4090 24GB.

> Base: [ComfyUI](https://github.com/comfyanonymous/ComfyUI) `0.3.48` + [leejet/ComfyUI-GGUF](https://github.com/leejet/ComfyUI-GGUF) as RunPod serverless API. Fork of [runpod-workers/worker-comfyui](https://github.com/runpod-workers/worker-comfyui).

<p align="center"><img src="assets/worker_sitting_in_comfy_chair.jpg" title="Worker sitting in comfy chair" /></p>

**Status: fixed** — Qwen 2.1 uses `comfy/text_encoders/qwen_image21.py` (`TextEncodeQwenImage21` + `QwenImage21Cache`, `triton.language`) + `diffusers>=0.37` + `transformers>=5.17`. This repo is now tailormade, not a clone of `qwen-fast` (Rapid-AIO 1.0).

---

## What changed vs darkcoal-qwen-fast (2509) — and vs broken 2.1

| | `darkcoal-qwen-fast` (Rapid-AIO `qwen-image-edit` 1.0) | `darkcoal-qwen-2.1` **fixed** |
|---|---|---|
| Model | Phil Rapid-AIO v5.3 Q6_K 20B (4-step, `TextEncodeQwenImageEditPlus`) | `Qwen/Qwen-Image-2.1` 7B via **abenzerps UC GGUF** (`qwen-image-2.1-UC-Q4_K_M.gguf` 4.6GB) + **Heretic Q4_K_M** Qwen3-VL (4GB uncensored) |
| Nodes | `CLIPTextEncode` / `TextEncodeQwenImageEditPlus` + `ModelSamplingAuraFlow shift 3.1` + `EmptySD3LatentImage` | **`TextEncodeQwenImage21` + `QwenImage21Cache` + `EmptyLatentImage`** (native, no AuraFlow, no SD3 latent) |
| ComfyUI | `0.29.0` | `0.3.48` with `qwen_image21.py` |
| GGUF fork | `city96/ComfyUI-GGUF` + Phr00t patch | **`leejet/ComfyUI-GGUF`** (native `qwen_image21` arch, per HF docs) |
| Triton | not needed | **`build-essential gcc/g++` + `CC=gcc CXX=g++ TRITON_CACHE_DIR=/tmp/triton_cache` + `triton.language` verify** |
| Edit refs | 1-4 via Plus | **1-16 via `TextEncodeQwenImage21(images={image_1..image_16})` + `<image1>` in prompt** |
| VAE | `qwen_image_vae.safetensors` | **`qwen_image_2.1_vae_bf16.safetensors` (676MB, Comfy-Org)** + alias `qwen_image_vae.safetensors` |
| Speed | 4 steps ~6-8s | **40 steps euler/simple cfg1 ~15-20s 1024px** (KV-cache `QwenImage21Cache auto`) |

## Network volume (source of truth: abenzerps HF)

Servers: `/runpod-volume/models/...`  Pods: `/workspace/models/...` (same volume). See `docs/network-volumes.md` + `setup_network_volume.sh`.

Expected (volume-native, GGUFs NOT baked — VAE stub baked only):
```
/runpod-volume/models/
  diffusion_models/qwen-image-2.1-UC-Q4_K_M.gguf                 # abenzerps 4.60GB (alias qwen-image-2.1-uncensored-Q4_K_M.gguf)
  diffusion_models/qwen-image-2.1-UC-Q6_K.gguf / -Q8_0.gguf      # optional larger quants, swap via unet_name
  text_encoders/qwen-image-2.1-text-encoder-uncensored-Q4_K_M.gguf  # pottokao Heretic 4GB
  text_encoders/qwen-image-2.1-text-encoder-uncensored-mmproj-f16.gguf # 1.35GB
  text_encoders/qwen3vl_8b_int8_convrot.safetensors              # optional HF Comfy-Org 9.35GB (swap clip_name + CLIPLoader)
  vae/qwen_image_2.1_vae_bf16.safetensors                        # Comfy-Org 676MB (alias qwen_image_vae.safetensors)
  loras/                                                         # optional
```

Populate via Pod (or run `setup_network_volume.sh`):
```bash
chmod +x setup_network_volume.sh && ./setup_network_volume.sh
# or manually:
mkdir -p /runpod-volume/models/text_encoders /runpod-volume/models/diffusion_models /runpod-volume/models/vae
curl -L -C - -o /runpod-volume/models/diffusion_models/qwen-image-2.1-UC-Q4_K_M.gguf https://huggingface.co/abenzerps/Qwen-Image-2.1-Uncensored-GGUF/resolve/main/qwen-image-2.1-UC-Q4_K_M.gguf
curl -L -C - -o /runpod-volume/models/text_encoders/qwen-image-2.1-text-encoder-uncensored-Q4_K_M.gguf https://huggingface.co/pottokao/Qwen-Image-2.1-Text-Encoder-Heretic-GGUF/resolve/main/qwen3vl_8b_heretic-Q4_K_M.gguf
curl -L -C - -o /runpod-volume/models/text_encoders/qwen-image-2.1-text-encoder-uncensored-mmproj-f16.gguf https://huggingface.co/pottokao/Qwen-Image-2.1-Text-Encoder-Heretic-GGUF/resolve/main/mmproj-qwen3vl_8b_heretic-f16.gguf
curl -L -C - -o /runpod-volume/models/vae/qwen_image_2.1_vae_bf16.safetensors https://huggingface.co/Comfy-Org/Qwen-Image-2.1/resolve/main/vae/qwen_image_2.1_vae_bf16.safetensors
ln -sf qwen_image_2.1_vae_bf16.safetensors /runpod-volume/models/vae/qwen_image_vae.safetensors
ln -sf qwen-image-2.1-UC-Q4_K_M.gguf /runpod-volume/models/diffusion_models/qwen-image-2.1-uncensored-Q4_K_M.gguf
```
Verify: `ls -lh /runpod-volume/models/text_encoders/ /runpod-volume/models/diffusion_models/ /runpod-volume/models/vae/`

## Workflows

- `test_input.json` — T2I: `VAELoader` + `UnetLoaderGGUF(UC-Q4_K_M)` + `CLIPLoaderGGUF(Heretic Q4_K_M, type=qwen_image)` → `TextEncodeQwenImage21(prompt, resolution 1024)` + `EmptyLatentImage` → `KSampler(40 euler/simple cfg1)` → `VAEDecode`
- `test_input_edit.json` — Edit: same loaders + `LoadImage(reference.png)` → `TextEncodeQwenImage21(images={image_1}, vae, resolution 1024)` + `QwenImage21Cache` → `KSampler latent=[55,2]` (up to 10 refs, `<image1>` in prompt, RGBA via `This is an RGBA image...`)
- `playground.html` — `buildWorkflow()` now mirrors above (no `ModelSamplingAuraFlow`, no `CLIPTextEncode`).

## Build

```bash
docker build --platform linux/amd64 -t ghcr.io/alfa-jim/darkcoal-qwen-2.1:latest --build-arg MODEL_TYPE=qwen-2.1 --build-arg USE_NETWORK_VOLUME=true .
# Verify triton: docker run --rm ghcr.io/alfa-jim/darkcoal-qwen-2.1:latest python -c "import triton.language; print('ok')"
```

`docker-bake.hcl` target `qwen-2.1` uses `BASE_IMAGE=nvidia/cuda:12.6.3-cudnn-runtime-ubuntu24.04` + `COMFYUI_VERSION=0.3.48`.
