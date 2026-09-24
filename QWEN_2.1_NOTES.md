# Qwen 2.1 - Q4 Uncensored Default

Wired to **Q4 uncensored** (your request) - ~10GB total, fits 16GB VRAM, cheapest/fastest for experiment.

## Default quant (now in test_input.json)

- **Transformer (DiT 7B):** qwen-image-2.1-uncensored-Q4_K_M.gguf **~3.8GB** (Q4_K_M)
- **Text encoder (Qwen3-VL 8B):** qwen-image-2.1-text-encoder-uncensored-Q4_K_M.gguf **~4GB** + qwen-image-2.1-text-encoder-uncensored-mmproj-f16.gguf **~1.35GB**
- **VAE:** qwen_image_2.1_vae.safetensors **~0.8GB** (from Qwen/Qwen-Image-2.1/vae)

**Total:** ~10GB volume, ~12-13GB VRAM, 40 steps euler/simple cfg1 ~15-20s 1024px (lighter than fast's 18GB).

Other Q4 variants on same HF repo you can swap by changing unet_name:
- Q4_0 ~3.4GB (smaller, slightly more artifact)
- Q6_K ~5.5GB (better, needs 18GB VRAM)
- Q8_0 ~7.5-8GB (you remembered - transformer alone 8GB, best GGUF, ~13GB total)

## Populate volume (Pod terminal - serverless sees same at /runpod-volume)

mkdir -p /runpod-volume/models/text_encoders /runpod-volume/models/diffusion_models /runpod-volume/models/vae /runpod-volume/models/loras

# Q4 uncensored GGUF (community - arudradey/qwen-image-2.1-uncensored-gguf is primary, ghostrider761/tung776 mirrors)
curl -L -C - -o /runpod-volume/models/text_encoders/qwen-image-2.1-text-encoder-uncensored-Q4_K_M.gguf https://huggingface.co/arudradey/qwen-image-2.1-uncensored-gguf/resolve/main/qwen-image-2.1-text-encoder-Q4_K_M.gguf
curl -L -C - -o /runpod-volume/models/text_encoders/qwen-image-2.1-text-encoder-uncensored-mmproj-f16.gguf https://huggingface.co/arudradey/qwen-image-2.1-uncensored-gguf/resolve/main/qwen-image-2.1-mmproj-f16.gguf
curl -L -C - -o /runpod-volume/models/diffusion_models/qwen-image-2.1-uncensored-Q4_K_M.gguf https://huggingface.co/arudradey/qwen-image-2.1-uncensored-gguf/resolve/main/qwen-image-2.1-uncensored-Q4_K_M.gguf
curl -L -C - -o /runpod-volume/models/vae/qwen_image_2.1_vae.safetensors https://huggingface.co/Qwen/Qwen-Image-2.1/resolve/main/vae/diffusion_pytorch_model.safetensors

# Verify
ls -lh /runpod-volume/models/text_encoders/ /runpod-volume/models/diffusion_models/ /runpod-volume/models/vae/

# Alternative: official safetensors (33GB, censored base, no uncensor)
# huggingface-cli download Qwen/Qwen-Image-2.1 --local-dir /tmp/q21 --include "vae/*" "transformer/*" "text_encoder/*"
# mv /tmp/q21/transformer/* /runpod-volume/models/diffusion_models/; mv /tmp/q21/text_encoder/* /runpod-volume/models/text_encoders/

## Workflow

test_input.json = T2I 2048 40-step Q4
test_input_edit.json = edit 1-ref (supports up to 10x image1..10 + target_latent in 2.1, RGBA via prompt "This is an RGBA image with transparency...")

KSampler locked: steps=40 cfg=1 euler/simple denoise=1 shift=3.1 - not 4-step Rapid.
