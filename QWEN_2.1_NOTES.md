# Qwen 2.1 - GGUF Tailormade (abenzerps UC + pottokao Heretic)

Source of truth: **https://huggingface.co/abenzerps/Qwen-Image-2.1-Uncensored-GGUF** (UC GGUFs) + **https://huggingface.co/pottokao/Qwen-Image-2.1-Text-Encoder-Heretic-GGUF** (Heretic Qwen3-VL) + **https://huggingface.co/Comfy-Org/Qwen-Image-2.1** (VAE + int8 text encoder). Official workflows: `Comfy-Org/workflow_templates` `image_qwen_image_2_1_t2i.json` / `image_qwen_image_2_1_image_edit.json`.

Wired to **Q4 uncensored GGUF** - ~10.6GB total, fits 16GB VRAM, cheapest/fastest for experiment (lighter than fast's 21GB).

## Default quant (now in test_input.json + playground.html)

- **Transformer (DiT 7B):** `qwen-image-2.1-UC-Q4_K_M.gguf` **4.60GB** (Q4_K_M, HF canonical `UC`) + alias `qwen-image-2.1-uncensored-Q4_K_M.gguf` for backward compat
- **Text encoder (Qwen3-VL 8B Heretic uncensored):** `qwen-image-2.1-text-encoder-uncensored-Q4_K_M.gguf` **~4GB** (`qwen3vl_8b_heretic-Q4_K_M.gguf`) + `qwen-image-2.1-text-encoder-uncensored-mmproj-f16.gguf` **1.35GB** (`mmproj-qwen3vl_8b_heretic-f16.gguf`)
- **VAE:** `qwen_image_2.1_vae_bf16.safetensors` **676MB** (Comfy-Org `vae/qwen_image_2.1_vae_bf16.safetensors`, HF table) + alias `qwen_image_vae.safetensors`

**Total:** ~10.6GB volume, ~12GB VRAM at 1024², 40 steps euler/simple cfg1 ~15-20s (KV-cache `QwenImage21Cache auto`).

Alt (HF recommended, censored base): `qwen3vl_8b_int8_convrot.safetensors` **9.35GB** via `CLIPLoader type=qwen_image` (swap `clip_name` in workflow, keep Heretic for uncensored).

Other UC quant variants on abenzerps (swap `unet_name`):
- `qwen-image-2.1-UC-Q4_0.gguf` 4.15GB (smaller, more artifact)
- `qwen-image-2.1-UC-Q6_K.gguf` 5.88GB (better, needs ~14GB VRAM)
- `qwen-image-2.1-UC-Q8_0.gguf` 7.59GB (best GGUF)
- `qwen-image-2.1-UC-Q5_K_M.gguf` 5.22GB

ComfyUI stack: `0.3.48` + `leejet/ComfyUI-GGUF` (native `qwen_image21` arch) + `TextEncodeQwenImage21` + `triton` (needs `gcc` + `CC=gcc` at runtime).

## Populate volume (Pod terminal - serverless sees same at /runpod-volume)

```bash
mkdir -p /runpod-volume/models/text_encoders /runpod-volume/models/diffusion_models /runpod-volume/models/vae /runpod-volume/models/loras

# Heretic text encoder (uncensored, ~4GB + 1.35GB mmproj)
curl -L -C - -o /runpod-volume/models/text_encoders/qwen-image-2.1-text-encoder-uncensored-Q4_K_M.gguf https://huggingface.co/pottokao/Qwen-Image-2.1-Text-Encoder-Heretic-GGUF/resolve/main/qwen3vl_8b_heretic-Q4_K_M.gguf
curl -L -C - -o /runpod-volume/models/text_encoders/qwen-image-2.1-text-encoder-uncensored-mmproj-f16.gguf https://huggingface.co/pottokao/Qwen-Image-2.1-Text-Encoder-Heretic-GGUF/resolve/main/mmproj-qwen3vl_8b_heretic-f16.gguf

# DiT UC GGUF (4.60GB, Q4_K_M)
curl -L -C - -o /runpod-volume/models/diffusion_models/qwen-image-2.1-UC-Q4_K_M.gguf https://huggingface.co/abenzerps/Qwen-Image-2.1-Uncensored-GGUF/resolve/main/qwen-image-2.1-UC-Q4_K_M.gguf
ln -sf qwen-image-2.1-UC-Q4_K_M.gguf /runpod-volume/models/diffusion_models/qwen-image-2.1-uncensored-Q4_K_M.gguf

# VAE bf16 (676MB, canonical)
curl -L -C - -o /runpod-volume/models/vae/qwen_image_2.1_vae_bf16.safetensors https://huggingface.co/Comfy-Org/Qwen-Image-2.1/resolve/main/vae/qwen_image_2.1_vae_bf16.safetensors
ln -sf qwen_image_2.1_vae_bf16.safetensors /runpod-volume/models/vae/qwen_image_vae.safetensors

# Verify
ls -lh /runpod-volume/models/text_encoders/ /runpod-volume/models/diffusion_models/ /runpod-volume/models/vae/
# or: ./setup_network_volume.sh --verify
```

Alt official safetensors (33GB, censored base, no uncensor):
```bash
huggingface-cli download Qwen/Qwen-Image-2.1 --local-dir /tmp/q21 --include "vae/*" "transformer/*" "text_encoder/*"
# mv /tmp/q21/transformer/* /runpod-volume/models/diffusion_models/; mv /tmp/q21/text_encoder/* /runpod-volume/models/text_encoders/
```

## Workflows

- `test_input.json` = T2I 1024 40-step Q4 via `TextEncodeQwenImage21` + `EmptyLatentImage` (resolution 1024, euler/simple cfg1)
- `test_input_edit.json` = edit 1-ref via `TextEncodeQwenImage21(images={image_1}, vae, resolution 1024)` + `QwenImage21Cache` + latent `[55,2]` (supports up to 16 refs `image_1..16`, reference `<image1>` in prompt, RGBA via prompt prefix `This is an RGBA image with transparency...`)
- No `ModelSamplingAuraFlow` (Qwen 2.1 native), no `EmptySD3LatentImage` (use `EmptyLatentImage`), no `CLIPTextEncode`.

KSampler locked: `steps=40 cfg=1 euler/simple denoise=1` — not 4-step Rapid. Change `resolution` for larger output (2048 = native 2K, needs 24GB).
