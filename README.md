# darkcoal-qwen-2.1

> Experimental fork of [darkcoal-qwen-fast](https://github.com/Alfa-jim/darkcoal-qwen-fast) for **Qwen-Image 2.1** (Qwen/Qwen-Image-2.1 - 7B visual DiT, 33GB) - unified T2I + image editing + native RGBA + up to 10 refs. Network-volume-native (/runpod-volume) for RunPod 4090 24GB.

> Base: [ComfyUI](https://github.com/comfyanonymous/ComfyUI) as RunPod serverless API. Fork of [runpod-workers/worker-comfyui](https://github.com/runpod-workers/worker-comfyui).

<p align="center"><img src="assets/worker_sitting_in_comfy_chair.jpg" title="Worker sitting in comfy chair" /></p>

**Status: experimental** - Qwen-Image 2.1 is diffusers QwenImage21Pipeline (transformer 7B BF16, Qwen3-VL text encoder, VAE 16x). Requires ComfyUI >=0.3.43 + diffusers>=0.37.

---

## What changed vs darkcoal-qwen-fast (2509)

| | darkcoal-qwen-fast (2509) | darkcoal-qwen-2.1 |
|---|---|---|
| Model | Phil Rapid-AIO v5.3 Q6_K 20B (4-step) | Qwen/Qwen-Image-2.1 7B (40-step native) |
| Size | ~21GB GGUF | ~33GB safetensors / ~18GB GGUF uncensored est. |
| VRAM | ~19GB | ~16-18GB BF16 |
| Edit | 1-4 refs Plus node | up to 10 refs, circles/paint/masks, native RGBA |
| Speed | 4 steps ~6-8s | 40 steps ~15-20s 1024px (KV-cache) |

## Network volume (same foldering as qwen-fast)

Servers: /runpod-volume/models/...  Pods: /workspace/models/... (same volume). See docs/network-volumes.md.

Expected:
/runpod-volume/models/
  vae/  -> qwen_image_2.1_vae.safetensors (vae/diffusion_pytorch_model.safetensors)
  text_encoders/ -> Qwen3-VL shards or GGUF (Q4_K_M + mmproj-f16)
  diffusion_models/ -> transformer shards or GGUF Q6_K
  loras/ -> optional

Populate via Pod: curl -L -C - -o /runpod-volume/models/vae/... https://huggingface.co/Qwen/Qwen-Image-2.1/resolve/main/vae/diffusion_pytorch_model.safetensors
# transformer: 2 shards, text_encoder: 4 shards - or use GGUF community (arudradey/qwen-image-2.1-uncensored-gguf)

## Build

docker build --platform linux/amd64 -t ghcr.io/alfa-jim/darkcoal-qwen-2.1:latest --build-arg MODEL_TYPE=qwen-2.1 --build-arg USE_NETWORK_VOLUME=true .
