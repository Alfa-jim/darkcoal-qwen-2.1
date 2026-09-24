# Darkcoal Qwen Fast — Deep Dive for Backend / Proxy Integration

> **Repo:** `darkcoal-qwen-fast/` (fork of `runpod-workers/worker-comfyui`)
> **Model:** Phil / Phr00t **Rapid-AIO v5.3 NSFW** — 4-step accelerated `Qwen-Image-Edit`
> **Stack:** `qwen-rapid-nsfw-v5.3-Q6_K.gguf` (UNet ~13GB) + `Qwen2.5-VL-7B-Instruct-abliterated.Q4_K_M.gguf` (CLIP + Vision, ~4GB) + `Qwen2.5-VL-7B-Instruct-abliterated.mmproj-f16.gguf` (vision projector, 1.35GB) + `qwen_image_vae.safetensors` (VAE) + optional `qwen-anime-irl.safetensors` LoRA + `ModelSamplingAuraFlow shift 3.1`
> **Nodes:** `UnetLoaderGGUF / CLIPLoaderGGUF / VAELoader / ModelSamplingAuraFlow / TextEncodeQwenImageEditPlus(v2) / CLIPTextEncode / EmptySD3LatentImage / KSampler / VAEDecode / SaveImage+(PreviewImage)`
> **Locked sampler:** `steps=4, cfg=1.0, sampler_name=euler_ancestral, scheduler=beta, denoise=1.0, shift=3.1`
> **Image:** `ghcr.io/alfa-jim/darkcoal-qwen-fast:late2` (also `:latest`/`:qwen-image-edit` — same digest `a216b4b`)
> **Playground reference:** `darkcoal-qwen-fast/playground.html` — canonical client that mirrors every rule below.

This doc is for an AI coding assistant that will build a **Supabase Edge Function (proxy) + billing** between Darkcoal's app and the RunPod Serverless endpoint. Cover every request/response shape, workflow graph, native Qwen abilities, auto-size, multi-ref, and batch semantics.

---

## 1. How to call it

### 1.1 Endpoints (RunPod Serverless)

```
POST https://api.runpod.ai/v2/<ENDPOINT_ID>/runsync   # synchronous (waits, but may still return IN_QUEUE/IN_PROGRESS on timeout)
POST https://api.runpod.ai/v2/<ENDPOINT_ID>/run        # async — returns {id}, poll GET /status/<id>
GET  https://api.runpod.ai/v2/<ENDPOINT_ID>/status/<JOB_ID>
GET  https://api.runpod.ai/v2/<ENDPOINT_ID>/health
```

**Headers every call needs:**
```
Authorization: Bearer <RUNPOD_API_KEY>   # rpa_… (service key — never expose to client; Supabase proxy holds it)
Content-Type: application/json
```

`ENDPOINT_ID` looks like `q6dvplx1kq2i5n` (in logs/playground). Find in RunPod Console → Serverless → Endpoint → ID / Overview.

### 1.2 Request / Response shape (handler.py §150-944)

`handler.py:validate_input` and `handler()` define the contract:

**Request:**
```json
{
  "input": {
    "workflow": { "<node_id>": { "inputs": {...}, "class_type": "<NodeType>" } },
    "images": [
      { "name": "ref.png",  "image": "data:image/png;base64,iVBOR…" },
      { "name": "ref2.png", "image": "data:image/png;base64,iVBOR…" }
    ],
    "comfy_org_api_key": "optional-per-request Comfy.org API Nodes key (overrides COMFY_ORG_API_KEY env)"
  }
}
```

Field rules:
- `input.workflow: object` — **required**. Keys are string node IDs (e.g. `"10"`, `"61"`). Values must have `class_type` + `inputs`. Must be exported in **API format** (`Workflow → Export (API)`), not UI format.
- `input.images?: {name,image}[]` — **optional**. `name` is filename referenced by `LoadImage.image` in the workflow. `image` is base64; `data:image/png;base64,` prefix is optional and stripped by the handler (`handler.py:upload_images` splits on `,` and `base64.b64decode`s). Must be unique names per call.
- `input.comfy_org_api_key?: string` — optional, forwarded as `extra_data.api_key_comfy_org` to `/prompt`.
- RunPod-level caps: `~10MB /run, ~20MB /runsync` inc. base64. **Do not send >4 refs or >2MB JPEG each without resizing.** Client should `toDataURL('image/jpeg', 0.92)` or cap `max ~1536px`.

**Success output (images):**
```json
{
  "id": "sync-…",
  "status": "COMPLETED",
  "output": {
    "images": [
      { "filename": "ComfyUI_00001_.png", "type": "base64", "data": "iVBOR…" },
      { "filename": "ComfyUI_00001_.png", "type": "s3_url", "data": "https://bucket…/ComfyUI_00001_.png" }
    ]
  },
  "delayTime": 912,
  "executionTime": 510
}
```

- `output.images` — always present on success (may be `[]` if workflow produced no `SaveImage`). `type` is `"base64"` by default, `"s3_url"` iff `BUCKET_ENDPOINT_URL` is set on the worker (S3 upload via `runpod.serverless.utils.rp_upload`).
- `output.errors?: string[]` — warnings (e.g. skipped `temp` images, S3 upload errors) even on success.

**Failure outputs:**
```json
{ "error": "Missing 'workflow' parameter" }                       // validate_input
{ "error": "Failed to upload one or more input images", "details": ["…"] } // upload_images
{ "error": "Job processing failed", "details": ["Workflow execution error: Node Type: …, Node ID: …, Message: …"] } // ComfyUI execution_error
{ "error": "Workflow validation failed:\n• Node 27 …\n• Node 12 …" } // /prompt 400 + object_info diagnostics
{ "error": "ComfyUI server (127.0.0.1:8188) not reachable…" }     // check_server
```

On **validation 400**, the handler enriches with `get_available_models()` (`/object_info`) e.g.:
```
Available models: unet_name: [qwen-rapid-nsfw-v5.3-Q6_K.gguf]  clip_name: [Qwen2.5-VL-7B-Instruct-abliterated.Q4_K_M.gguf]  vae_name: [qwen_image_vae.safetensors]
Hint: unet_name/clip_name list is empty => volume not attached or files not at /runpod-volume/models/{text_encoders,diffusion_models}/
```

**Timeout / queue behavior (`/runsync`):**
- The worker internally polls ComfyUI via websocket; wall time may exceed the HTTP timeout. Edge case: `/runsync` may return without `output` but with `id` + `status: IN_QUEUE | IN_PROGRESS`. Treat as **async** — poll `GET /status/<id>` with `Authorization` header, 1.5s interval, up to ~400 polls (10 min). Playground (`playground.html:420-485`) does exactly this: if `!data.output` and `status IN_QUEUE/IN_PROGRESS`, switch to poll loop.

**Polling logic to copy (playground.html:generate):**
1. `POST /run` or `POST /runsync` → if `data.id` and not `data.output`, or `status IN_QUEUE/IN_PROGRESS` → poll `GET /status/<id>`.
2. `COMPLETED | status plus sData.output` → break, `out = sData.output || sData`.
3. `FAILED|ERROR` → throw `job failed: {JSON}`.
4. Log each `status`, hint `Qwen 20B takes 60-90s execution + queue`.

---

## 2. Workflow graphs (exact payloads the worker expects)

All use the same 4 loaders + sampler. `_meta.title` is optional. **Locked values** (Rapid-AIO contract — do not change):
`shift=3.1, steps=4, cfg=1.0, sampler_name=euler_ancestral, scheduler=beta, denoise=1.0` (alt NSFW-favored: `lcm/normal` also valid; `euler/simple 30` is WRONG for Rapid).

### 2.1 Text-to-Image (no reference) — `test_input.json`

Canonical file at `darkcoal-qwen-fast/test_input.json` after migration — matches `playground.html:buildWorkflow()` when `mode==='txt2img'`:

```json
{
  "input": {
    "workflow": {
      "10": { "inputs": { "vae_name": "qwen_image_vae.safetensors" }, "class_type": "VAELoader" },
      "12": { "inputs": { "unet_name": "qwen-rapid-nsfw-v5.3-Q6_K.gguf" }, "class_type": "UnetLoaderGGUF" },
      "61": { "inputs": { "clip_name": "Qwen2.5-VL-7B-Instruct-abliterated.Q4_K_M.gguf", "type": "qwen_image", "device": "default" }, "class_type": "CLIPLoaderGGUF" },
      "66": { "inputs": { "shift": 3.1, "model": ["12", 0] }, "class_type": "ModelSamplingAuraFlow" },
      "6":  { "inputs": { "text": "<positive prompt>", "clip": ["61", 0] }, "class_type": "CLIPTextEncode" },
      "7":  { "inputs": { "text": " ", "clip": ["61", 0] }, "class_type": "CLIPTextEncode" },
      "27": { "inputs": { "width": 832, "height": 1216, "batch_size": 1 }, "class_type": "EmptySD3LatentImage" },
      "3":  { "inputs": { "seed": 42, "steps": 4, "cfg": 1.0, "sampler_name": "euler_ancestral", "scheduler": "beta", "denoise": 1.0, "model": ["66", 0], "positive": ["6", 0], "negative": ["7", 0], "latent_image": ["27", 0] }, "class_type": "KSampler" },
      "8":  { "inputs": { "samples": ["3", 0], "vae": ["10", 0] }, "class_type": "VAEDecode" },
      "9":  { "inputs": { "filename_prefix": "ComfyUI", "images": ["8", 0] }, "class_type": "SaveImage" }
    }
  }
}
```

`handler.py:upload_images` skipped, `input.images` omitted. `batch_size` may be 1-4; playground exposes it.

### 2.2 Single-reference Edit — `test_input_edit.json`

`darkcoal-qwen-fast/test_input_edit.json` + `playground.html:buildWorkflow()` when `mode==='edit'` and `refs.length===1`:

```json
{
  "input": {
    "images": [{ "name": "reference.png", "image": "data:image/png;base64,…" }],
    "workflow": {
      "10": { "inputs": { "vae_name": "qwen_image_vae.safetensors" }, "class_type": "VAELoader" },
      "12": { "inputs": { "unet_name": "qwen-rapid-nsfw-v5.3-Q6_K.gguf" }, "class_type": "UnetLoaderGGUF" },
      "61": { "inputs": { "clip_name": "Qwen2.5-VL-7B-Instruct-abliterated.Q4_K_M.gguf", "type": "qwen_image", "device": "default" }, "class_type": "CLIPLoaderGGUF" },
      "41": { "inputs": { "image": "reference.png" }, "class_type": "LoadImage" },
      "27": { "inputs": { "width": 832, "height": 1216, "batch_size": 1 }, "class_type": "EmptySD3LatentImage" },
      "66": { "inputs": { "shift": 3.1, "model": ["12", 0] }, "class_type": "ModelSamplingAuraFlow" },
      "68": {
        "inputs": {
          "prompt": "keep the same girl, same face and outfit and art style, now she offers a box of chocolates with both hands toward viewer, everything else exactly the same, highly detailed, nsfw uncensored",
          "clip": ["61", 0],
          "vae": ["10", 0],
          "image1": ["41", 0],
          "target_latent": ["27", 0]
        },
        "class_type": "TextEncodeQwenImageEditPlus"
      },
      "69": { "inputs": { "text": " ", "clip": ["61", 0] }, "class_type": "CLIPTextEncode" },
      "31": { "inputs": { "seed": 42, "steps": 4, "cfg": 1.0, "sampler_name": "euler_ancestral", "scheduler": "beta", "denoise": 1.0, "model": ["66", 0], "positive": ["68", 0], "negative": ["69", 0], "latent_image": ["27", 0] }, "class_type": "KSampler" },
      "8":  { "inputs": { "samples": ["31", 0], "vae": ["10", 0] }, "class_type": "VAEDecode" },
      "9":  { "inputs": { "filename_prefix": "ComfyUI", "images": ["8", 0] }, "class_type": "SaveImage" }
    }
  }
}
```

Key points:
- `LoadImage.image` must equal `input.images[].name` exactly. Mismatch → execution error `LoadImage: file not found`.
- `TextEncodeQwenImageEditPlus` is the **Phr00t v2 patched node** (Dockerfile overwrites `comfy_extras/nodes_qwen.py` with `https://huggingface.co/Phr00t/Qwen-Image-Edit-Rapid-AIO/resolve/main/fixed-textencode-node/nodes_qwen.v2.py`). It exposes:
  ```
  clip (Clip), prompt (String), vae (Vae? optional), image1..image4 (Image? optional), target_latent (Latent? optional) → Conditioning
  ```
  Actual schema (file inspect): `clip`, `prompt`, `vae`, `image1`, `image2`, `image3`, `image4`, `target_latent`. Old code used `latent` (wrong) — real param is `target_latent`. `target_latent` should be wired to the same `EmptySD3LatentImage` output (`["27",0]`) for correct aspect-aware scaling (otherwise it falls back to `384x384 center lanczos` and crops).
  Inside: `prompt` is prepended with per-image `Picture N: <|vision_start|><|image_pad|><|vision_end|>` tokens and `clip.tokenize(prompt, images=images_vl, llama_template=…)`. `ref_latents` are VAE-encoded (upscaled via `target_latent` dims if present, else native) and injected as `conditioning` `reference_latents`. See `nodes_qwen.v2.py` § plus.
- `EmptySD3LatentImage` **defines output size** (not the reference). `width/height` in `[512,1536]` snapped `/64` (see §3).
- Negative is always `" "` (space) — Qwen uses empty negative; the playground's `negWrap` is hidden and `buildWorkflow` sends `" "`.
- No `VAEEncode` img2img — reference is encoded inside `TextEncodeQwenImageEditPlus` via its `vae` + `target_latent` inputs.
- `batch_size` on `EmptySD3LatentImage` controls how many samples per call (1-4). To generate multiple variants per prompt, bump `batch_size` (handler loops `outputs` and returns every `images` entry) — cheaper than N calls but shares seed (+ offset per batch item internally).

### 2.3 Multi-reference (up to 4) — playground's current multi

`playground.html:buildWorkflow()` edit branch now loops `refs[0..3]`:

```js
const plusInputs = { prompt, clip: clipRef, vae: vaeRef, target_latent: ["27",0] };
plusInputs.prompt = plusInputs.prompt
  .replace(/@ref1/gi,"Picture 1").replace(/@ref2/gi,"Picture 2")
  .replace(/@ref3/gi,"Picture 3").replace(/@ref4/gi,"Picture 4");
for(let i=0;i<Math.min(refs.length,4);i++){
  const nid = String(41+i);
  wf[nid] = { inputs:{ image: refs[i].name }, class_type:"LoadImage" };
  plusInputs[`image${i+1}`] = [nid,0];
}
wf["6"] = { inputs: plusInputs, class_type:"TextEncodeQwenImageEditPlus" };
```

**Conventions:**
- Drop order → tag: 1st file `ref.png` → `@ref1`/`Picture 1`; 2nd `ref2.png` → `@ref2`/`Picture 2`; etc.
- Prompt tagging: user writes `@ref1 wears @ref2` → playground normalizes to `Picture 1 wears Picture 2` before sending. The Plus node's internal `llama_template` is `Picture N:` aware: `"Describe key details of the input image… then how instruction should alter… Generate new image that meets requirements, can vary from small change to completely new image using inputs as guide."`
- Example prompt (the proven one for outfit transfer):
  ```
  keep face and hair from Picture 1, outfit and colors from Picture 2, Picture 1 wears the outfit from Picture 2, full body shot, entire head and face visible, centered, head to knees, white background, highly detailed anime
  ```
  For the maid case (ref1=girl, ref2=mannequin torso) add `full body shot, entire head visible` and portrait size `832x1216` to avoid crop.
- `input.images` array length = `refs.length`, names must match each `LoadImage`. The handler uploads all then ComfyUI resolves.
- `clip.encode_from_tokens_scheduled` accepts `images=images_vl` (internally `384*384` VL path via `lanczos center` + reference path via `lanczos center` upscaled to `target_latent` dims). So aspect matters (§3).

---

## 3. Size / Auto-Scale (the most common bug)

### 3.1 Control surface

- **Producer:** `EmptySD3LatentImage {width,height,batch_size}` — output canvas. Valid `16..16384`, `step 16`, but Qwen/VRAM sweet spot is `512..1536` snapped `/64`. Playground dropdown offers `512/768/832/1024/1152/1280/1360/1536` + presets (`1:1 1024x1024`, `3:4 832x1216`, `4:3 1216x832`, `9:16 768x1360`, `16:9 1360x768`). `applyAR()` + `syncWH()` enforce `/64`.
- **Consumer:** `TextEncodeQwenImageEditPlus` scales each `image{i}`:
  - VL token path: `384*384` total area → `scale_by = sqrt(384*384 / (W*H))` → `common_upscale(..., "lanczos","center")` (crops).
  - Reference latent path: if `target_latent` present, `twidth/theight = target_latent.samples.shape[-1]*8` → `common_upscale(..., twidth, theight, "lanczos","center")` → `vae.encode(crop)`. If absent, falls back to native dims, still `center` crop.
- **Result:** a square `1024x1024` latent cropped a portrait ref's head (the bug users hit: `768x1216` ref → `1024x1024` → head cut). Fix: match `EmptySD3` to ref's aspect.

### 3.2 Auto-size (playground: onFiles → Image)

When `autoSize` toggle (default ON) and first ref drops, playground does:

```js
let w=Math.round(naturalWidth/64)*64, h=Math.round(naturalHeight/64)*64;
w=Math.max(512,Math.min(1536,w)); h=Math.max(512,Math.min(1536,h));
if(Math.max(w,h)>1216){ const s=1216/Math.max(w,h); w=Math.round(w*s/64)*64; h=Math.round(h*s/64)*64; }
$('width').value=w; $('height').value=h; $('ar').value='';
```

- Longest side capped `1216` for VRAM on `Q6_K @ 4090 24GB` (`832x1216 ~16GB, 1024² ~14GB`). `h` got `0 => 1024` guard in `buildWorkflow` (`if(!H || H<16) H=1024`).
- Multi-ref: only first drop triggers; subsequent drops keep dims (face ref convention). Optionally switch to "max among refs" if outfit bepaalt aspect differently.
- **Backend should replicate** if it wants "auto": read the first image's dimensions server-side (e.g. in Supabase function before calling RunPod, decode JPEG header or use `sharp`/`image-size`) and compute wall dims. Don't rely on client to send trustworthy dims — optionally accept `width?/height?` but fallback compute.

### 3.3 Invalid size errors

`EmptySD3LatentImage height 0 smaller than min 16` → client sent `768` width that wasn't in `<select>` parsed as `NaN` → `0`. Playground guard `if(!W||W<16) W=1024` fixes it. Ensure backend also guards `NaN` and snaps `/64`.

---

## 4. Payload functions (every field you can vary)

| Field | Where | Allowed | Default (Rapid-AIO) | Notes |
|-------|-------|---------|----------------------|-------|
| `vae_name` | `VAELoader` `10` | `qwen_image_vae.safetensors` (baked `/comfyui/models/vae + /runpod-volume/models/vae`) | — | Do not change; optional VAE GGUF `pig_qwen_image_vae_fp32-f16.gguf` exists but not baked. |
| `unet_name` | `UnetLoaderGGUF` `12` | `qwen-rapid-nsfw-v5.3-Q6_K.gguf` (current) | — | Alternatives on volume: `…-Q4_K_M.gguf`, `…-Q8_0.gguf`, `v90/qwen-rapid-nsfw-v9.0-…` etc. Pick per VRAM. |
| `clip_name` | `CLIPLoaderGGUF` `61` | `Qwen2.5-VL-7B-Instruct-abliterated.Q4_K_M.gguf` | — | Must pair with matching `mmproj`. `Q4_K_M` + `mmproj-f16` is required combo. `q4_0` (ChrisColeTech) is old censored. |
| `type` | `CLIPLoaderGGUF` `61` | `qwen_image` | — | Must be `qwen_image` for Qwen; otherwise clip won't tokenize images. |
| `shift` | `ModelSamplingAuraFlow` `66` | `float, 3.1` | `3.1` | RoPE shift for AuraFlow/Qwen; keep `3.1`. |
| `text` | `CLIPTextEncode` (txt2img) `6` | string | — | Full T2I prompt (e.g. `masterpiece anime, 1girl, …`). |
| `prompt` | `TextEncodeQwenImageEditPlus` `68/6` | string | — | **Edit instruction** — must state preservation: `keep the same girl, same face/outfit/style, now …` (see §2.2). In multi, include `Picture 1/2`. |
| `image` | `LoadImage` `41` | filename matching `input.images[].name` | `ref.png` etc. | First image. Multi adds `42/43/44`. |
| `image1..4` | `TextEncodeQwenImageEditPlus` | `[nodeId,0]` refs | — | Optional up to 4. |
| `target_latent` | `TextEncodeQwenImageEditPlus` | `[latentNodeId,0]` | `["27",0]` | **Must** be `EmptySD3LatentImage`'s output for correct scaling. Without it reference latent uses native dims and crops unexpected. |
| `width, height` | `EmptySD3LatentImage` `27` | `512..1536` snap `/64` | `832x1216` (edit) / `1024x1024` or `832x1216` (txt2img) | Use auto-size logic §3.2. |
| `batch_size` | `EmptySD3LatentImage` | `1..4` | `1` | Internally KSampler batches. To sample N images per call without N API calls. |
| `seed` | `KSampler` `31` | `int` `-1` random or actual int; playground maps `-1`→`Math.random()*2^31-1` | `42` fixed in examples | Pass distinct seeds if `batch_size >1`. |
| `steps` | `KSampler` | `int 4` for Rapid | `4` | **Locked.** `20-40` is for non-accelerated Qwen; Rapid will overcook. |
| `cfg` | `KSampler` | `1.0` | `1.0` | Locked Qwen flow; `4-6.5` are SDXL values that break Qwen. |
| `sampler_name` | `KSampler` | `euler_ancestral` (default) or `lcm` | `euler_ancestral` | Per Phr00t: v5.3 NSFW → `lcm/normal` best, `euler_ancestral/beta` equal. Avoid `euler/simple`. |
| `scheduler` | `KSampler` | `beta` (pairs with euler_ancestral) or `normal` (pairs with lcm) | `beta` | Same pairing: `euler_ancestral/beta`, `lcm/normal`. |
| `denoise` | `KSampler` | `1.0` | `1.0` | Full denoise edit (keep `--0.94` strength path unused — that's Fal's old 30-step field). |
| `lora_name` | `LoraLoader` `100+` | files in `/runpod-volume/models/loras/` or baked `/comfyui/models/loras/` (currently `qwen-anime-irl.safetensors`) | — | Chainable: `LoraLoader {lora_name,strength_model,strength_clip,model,clip}`. Playground auto-chains between `66` and `KSampler`. |

**Validation errors** like `Value 0 smaller than min of 16 (height)` or `not in list: unet_name/clip_name/vae_name` surface as `node_errors` with `Available models: …` — surface these in the proxy as 400 with the `availableModelsLine` (handler `get_available_models`).

---

## 5. Native Qwen capabilities (what to expose in immersifier)

- **I2I Edit with identity preservation:** The flagship. Single ref via `image1 + target_latent`; prompt must explicitly say what's KEPT (`same face/outfit/style/background`) plus what's CHANGED. Rough repro from codebase: `keep the same girl, same face, same outfit, same art style, now she offers a box of chocolates with both hands toward viewer`. Without the `keep …` clause identity drifts.
- **Multi-reference compositing (fusion):** `Plus` node's internal prompt builder joins `Picture 1/2/3/4` into a LLM-style template (`llama_template`) + VLM pushes each image through `Qwen2.5-VL` as `images_vl` (384-lanczos) while VAE builds `reference_latents[i]` per image (upscaled to `target_latent` dims). Fallback without LLaMA? Standard fallback exists but not loaded here — the active path is always the `llama_template` one.
- **Reference scaling control:** `target_latent` is the native knob. Wiring it yields center-cropped reference scaled to output. Not wiring yields `384` square VL path and VAE-native reference (usually wrong aspect). Auto-size on output avoids losing heads.
- **T2I + LoRA:** T2I path is pure flow (no VAE reference). LoRAs are handled by chaining `LoraLoader`s where `strength_model==strength_clip` (playground convention). Can mix anime-irl LoRA at e.g. `0.8` for anime or `0.0` for photo.
- **Batch & multi-prompt:** `batch_size` on `EmptySD3LatentImage` = multiple samples per call (sequential sampled, shared prompt). For multiple *prompts* from one reference set, issue **multiple API calls** (Playground `Generate` does 1 call; for "batch prompts" do serial `/runsync` or parallel with throttling). Do not concatenate prompts with `||` — Qwen's flow doesn't do alternative prompts.

---

## 6. How to wire the Supabase proxy (billing + proxy pattern)

### 6.1 Architecture

```
[App (web/mobile)] ──auth──▶ [Supabase: Edge Function / PG + pg_net]
                                │  1) auth + billing gate (get user, check coals, budget, RLS)
                                │  2) normalize → build workflow JSON (§2) + prepare images array
                                │  3) forward to RunPod Serverless (POST + optional poll)
                                │  4) persist output (store base64 as S3/Supabase Storage object, strip from JSON)
                                │  5) debit coals, insert generation log
                                └──────────▶ [RunPod: https://api.runpod.ai/v2/<ID>/runsync]
```

Never let clients talk to RunPod directly (would leak `rpa_…` and bypass billing). App sends `Bearer <Supabase JWT>` to the Edge Function; the function holds `RUNPOD_API_KEY` in `env`/`vault`.

### 6.2 Edge Function responsibilities (checklist)

1. **Auth:** `await supabase.auth.getUser()` on the request's `Authorization: Bearer <jwt>` (Supabase Edge Function helper). Reject 401 if absent.
2. **Input normalize:** Accept either:
   - `prompt: string` + optional `references: {dataUrl|base64,name}[]` (0 = txt2img, 1-4 = edit) + optional `size: {width,height}` or `autoSize: boolean` + optional `seed?`, `batch?`.
   - …or `workflow: object` passthrough for power users (admin only; still run billing gate).
   Enforce limits: `prompt <= 3000 chars`, `images 0..4`, each base64 `<= ~2MB` (reject >10MB total), `batch 1..4`, size clamped `512..1536` snap `/64`.
3. **Billing preview:** Map to coal cost **before** calling RunPod. Using the serverless economics from session:
   - Base: `std 7.1k cold-amortized, ref 10k cold-amortized` at `1M=$1`. But product pricing is `15k (std) / 25k (ref)` (decided: keep image cheap as loss-leader for 5x text margin). Optionally `20k/35k` as premium. Implement as `PRICE_STD=15000, PRICE_REF=25000` in config. Debit *pre-auth* (hold), refund on failure.
4. **Workflow build:** Call a shared `buildWorkflow(mode, prompt, sizes, seed, batch, refs)` that mirrors `playground.html:buildWorkflow()`. Reuse exactly the locked `shift/steps/cfg/sampler/scheduler/denoise` and the `target_latent` wiring (`refs 0→ txt2img branch`, `refs≥1→Plus branch`, `@refN → Picture N` replace). Do not re-implement from scratch — copy the function verbatim and make it run in Deno/Node (pure object construction).
5. **Size auto:** If `autoSize` true and `references[0]` provided, decode first image dims (e.g. `sharp` or tiny JPEG header parser; in Edge Function you can use `fetch` + `atob` + `image-size` or instantiate `Image` via `createImageBitmap` polyfill) and snap as §3.2. Override any caller-supplied dims.
6. **Upload/forward:** `POST https://api.runpod.ai/v2/<ID>/runsync` with `Authorization: Bearer <RUNPOD_API_KEY>` and `body: JSON.stringify({input:{workflow, ...(images?.length?{images}:{})}})`. Set function timeout `> 600s` for `runsync` (long running) — Supabase Edge Functions default 150s, so either use `run` + `poll` pattern, or run a **background pg_net http job** and return `job_id` immediately, streaming logs later. Playground already handles 10 min poll with 1.5s interval and auto-fallback when `runsync` returns `IN_QUEUE/IN_PROGRESS` without output.
7. **Status poll:** If initial response has `id` but not `output.images`, loop `GET /status/<id>` (1.5s, 400 attempts). Handle `COMPLETED` w/ `output.images`, else `FAILED|ERROR` → refund hold + surface error.
8. **Output persist:** `output.images[].data` can be multi-MB base64. Don't store in Postgres row. Upload to Supabase Storage bucket (e.g. `gens/<user>/<uuid>.png`), store URL, and **do not return base64** to the app — return the Storage signed URL or a `s3_url`-style object. If RunPod worker is configured with `BUCKET_ENDPOINT_URL` it already returns `s3_url`; proxy should just forward that.
9. **Debit & log:** On success: finalize debit (`coals -= PRICE_*`), insert into `generations` table (`user_id, mode, prompt, refs[], size, seed, cost, runpod_job_id, storage_urls, timings{delayTime,executionTime}`). On failure: release hold and return structured `error + details`.
10. **Batch prompts:** Two separate patterns:
    - `batch_size>1` inside `EmptySD3LatentImage`: expands one call into N images with same prompt (playground `batch` input). Map to `output.images.length == batch_size`.
    - `prompts: string[]` (N different prompts with same refs): loop N independent calls (serial or throttled concurrent; avoid hitting RunPod concurrency cap). Return an array of results; charge `N * PRICE_*`; wrap as one transaction so partial failures refund that index's hold.

### 6.3 Supabase specifics (Edge Function template)

```ts
// supabase/functions/qwen-proxy/index.ts
import { serve } from "https://deno.land/std@0.224/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { buildWorkflow, snap64, estimateCost } from "./qwen.ts";

serve(async (req) => {
  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const user = (await supabase.auth.getUser(req.headers.get("Authorization")!.replace("Bearer ",""))).data.user;
  if(!user) return Response.json({error:"401"}, {status:401});

  const body = await req.json();
  // body: { prompt, references?: {name,image}[], width?, height?, autoSize?, seed?, batch? } or { workflow, images }
  const refs = body.references ?? [];
  const mode = refs.length ? "edit" : "txt2img";
  // billing gate
  const price = mode==="edit" ? 25000 : 15000; // coals; 1M=$1 in your ledger — 15/25 is current, 20/35 premium knobs
  const holds = body.prompts ? body.prompts.length * price : price;
  // ... check balance, pre-debit/hold ...

  const wf = body.workflow ?? buildWorkflow({mode, prompt:body.prompt||body.prompts?.[0], refs, ...body});
  const images = refs.map((r,i)=>({name:r.name??`ref${i?i+1:""}.png`, image:r.image}));
  const resp = await fetch(`https://api.runpod.ai/v2/${Deno.env.get("RUNPOD_ENDPOINT_ID")}/runsync`, {
    method:"POST",
    headers:{Authorization:`Bearer ${Deno.env.get("RUNPOD_API_KEY")}`, "Content-Type":"application/json"},
    body: JSON.stringify({input:{workflow:wf, ...(images.length?{images}:{})}})
  });
  let data = await resp.json();
  if(!resp.ok) throw new Error(`RunPod ${resp.status}: ${JSON.stringify(data).slice(0,1200)}`);
  // poll fallback if needed (IN_QUEUE/IN_PROGRESS without output) — mirror playground
  if(data.id && (!data.output?.images)){
    const base = `https://api.runpod.ai/v2/${Deno.env.get("RUNPOD_ENDPOINT_ID")}`;
    for(let i=0;i<400;i++){
      await new Promise(r=>setTimeout(r,1500));
      const s = await fetch(`${base}/status/${data.id}`, {headers:{Authorization:`Bearer ${Deno.env.get("RUNPOD_API_KEY")}`}});
      const sj = await s.json();
      const st = (sj.status||sj.state)?.trim?.();
      if(st==="COMPLETED" || sj.output) { data = sj; break; }
      if(st==="FAILED"||st==="ERROR") throw new Error(JSON.stringify(sj).slice(0,4000));
    }
  }
  const out = data.output ?? data;
  if(out.error) throw new Error(out.error + (out.details?(" "+JSON.stringify(out.details).slice(0,2000)):""));
  // persist, finalize debit, return URLs
  return Response.json({images: out.images, status:"COMPLETED", price});
});
```

Harden with `try/catch`, release hold on `FAILED`, and rate-limit (`refs total base64 length`, `prompt length`, `batch <=4`).

---

## 7. Error catalog (what to surface to users vs logs)

| Symptom | Root | Fix for proxy to surface |
|---------|------|--------------------------|
| `404 job not found` | Polled stale `id` after `runsync` that already returned `output`, or called `/status` on wrong `ENDPOINT_ID` | Retry `runsync`; ensure poll uses same endpoint base |
| `No images in output: { delayTime, error: "Job processing failed", output:{details:[…]}, status: "FAILED" }` | ComfyUI `execution_error` per node | Surface `details[0]` verbatim (e.g. `Node 61 cannot reshape array of size 691328 into shape (1280,1280)` → mmproj mismatch; instruct to fix volume — see §8) |
| `cannot reshape array of size 691328 into shape (1280,1280)` | `clip_name` paired with wrong `mmproj` (e.g. `abliterated.Q4_K_M` + `mmproj-Q8_0` or truncated `mmproj-f16` at 7.7MB not 1.35GB) | Ensure volume has `Qwen2.5-VL-7B-Instruct-abliterated.mmproj-f16.gguf` 1.35GB next to `Q4_K_M`. Re-download with `--continue-at -`. |
| `Got unexpected keyword argument 'latent'` | Called `TextEncodeQwenImageEditPlus` with `latent` instead of `target_latent`, or stale worker image without v2 patch | Send `target_latent: ["27",0]` and ensure worker image is `:late2`/`:latest` `a216b4b` (Dockerfile patches `nodes_qwen.py` with `v2`). `latest`/`late2` are same digest. |
| `Value 0 smaller than min of 16 (height/width)` | EmptySD3LatentImage received `0` (playground sent `768` not in select → `NaN→0`) | Snap `/64` and guard `W||1024`/`H||1024` (playground fix). |
| `unet_name/clip_name not in [ ]` or `not in list` | Network volume not attached or wrong region/path or custom nodes missing | Check RunPod Console → Serverless → Advanced → Network Volume = `qwen-fast-models`, **same region** `CA`, files at `/runpod-volume/models/text_encoders/*.gguf`, `/runpod-volume/models/diffusion_models/*.gguf`; set `NETWORK_VOLUME_DEBUG=true` for diagnostics dump in logs |
| `mat1 and mat2 shapes cannot be multiplied (792x1280 and 3840x1280)` | `mmproj` missing or wrong file next to clip GGUF | Place `*.mmproj-f16.gguf` beside the clip gguf with matching `abliterated` prefix |
| `invalid JSON format` / `Missing workflow` | validate_input path | Ensure `input.workflow` object, not string; if string, handler tries `JSON.parse` but fails |

Always forward `error + details` from `data.output` — it already includes `Available models: …` on 400.

---

## 8. Infrastructure (serverless vs pod)

- **Production = Serverless** (`/runpod-volume`, not `/workspace`). The Pod example mounts the same Network Volume at `/workspace` — just **pod mount path `/workspace` vs serverless mount `/runpod-volume`** above — files auto-sync (same volume). When the Pod was terminated data persisted; `~18GB GGUFs` billed `~$0.10/GB/mo` even idle. Pods pay GPU only while running; stopping halts GPU charge. The Deep Dive's script that deleted `ChrisColeTech/...` shards and downloaded `Phil v53 Q6_K + abliterated` is canonical (§ later).
- **Volume contents for `late2`:**
  ```
  /runpod-volume/models/text_encoders/
    Qwen2.5-VL-7B-Instruct-abliterated.Q4_K_M.gguf              (~4.0GB)
    Qwen2.5-VL-7B-Instruct-abliterated.mmproj-f16.gguf          (~1.35GB, MUST be 1.35GB not 7.7M HTML)
  /runpod-volume/models/diffusion_models/
    qwen-rapid-nsfw-v5.3-Q6_K.gguf                              (~12-13GB)
  /runpod-volume/models/vae/qwen_image_vae.safetensors          (254MB)
  /runpod-volume/models/loras/  (optional, plus baked qwen-anime-irl.safetensors)
  ```
  Verify with `ls -lh … && du -sh /runpod-volume/models/*`. Corrupt `mmproj` at 7.7MB → re-fetch `Phil2Sat` HF URL.
- **Docker image** `darkcoal-qwen-fast/Dockerfile`:
  - Base `nvidia/cuda:12.6.3-cudnn-runtime-ubuntu24.04` + `torch 2.11.0 cu126` + `ComfyUI 0.29.0` + `ComfyUI-GGUF` + `gguf>=0.13.0 sentencepiece protobuf`.
  - **Critical patch** after GGUF install: `curl …/Phr00t/Qwen-Image-Edit-Rapid-AIO/blob/main/fixed-textencode-node/nodes_qwen.v2.py → /comfyui/comfy_extras/nodes_qwen.py` with `grep -q TextEncodeQwenImageEditPlus` assertion. Snapshot validation `extra_model_paths.yaml` (now `runpod_worker_comfy: base_path /runpod-volume` plus explicit `unet_gguf/clip_gguf`).
  - Staged as `final` from `qwen-downloader` (FAST: skip bake, volume-native). Build args: `MODEL_TYPE=qwen-image-edit, COMFYUI_VERSION=0.29.0, CUDA_VERSION_FOR_COMFY=12.6, USE_NETWORK_VOLUME=true`. Takes ~3 min FAST vs 12 min baked.
- **start.sh** guards volume + logs: checks `USE_NETWORK_VOLUME=true`, detects base `/runpod-volume` (serverless) or `/workspace` (pod compat was reverted to `/runpod-volume` only at commit `a216b4b`), echoes `FAST volume check OK` + `nodes_qwen.py check OK` (grep Plus), verifies `gguf` pip import & `ComfyUI-GGUF` dir, then launches `python -u /comfyui/main.py --disable-auto-launch … &` + `python -u /handler.py`.
- **handler.py** internals for proxy author to know: `check_server` polls `http://127.0.0.1:8188/` w/ PID file watch; `upload_images` POSTs each `input.images` to `http://127.0.0.1:8188/upload/image` (overwrites); `queue_workflow` POSTs `{"prompt":workflow,"client_id":clientId,"extra_data":{api_key_comfy_org}}` to `/prompt`; websocket `ws://127.0.0.1:8188/ws?clientId=…` waits for `executing {node:null, prompt_id}` (=done) or `execution_error`; `get_history/<prompt_id>` + `/view` fetches outputs; returns `{images:[{filename,type:"base64"|"s3_url",data}]}`. Environment may add `NETWORK_VOLUME_DEBUG=true`, `WEBSOCKET_TRACE`, `BUCKET_ENDPOINT_URL` for S3.

---

## 9. Billing numbers (for product)

- **GPU:** A5000 serverless `0.69/hr = 0.0001916/sec`, no idle (serverless). Warm: **std 25s = 4,791 coals**, **ref 40s = 7,666 coals** (at `1M=$1`). Cold start ~2 min amortized 1-in-10 → `+2,300` → `std 7.1k, ref 10k`. 40GB volume `$3-4/mo` negligible.
- **Sell as decided:** `15k standard / 25k ref` (alternative premium `20k/35k` — still under Fal's `0.03/MP` and under Candy/Spicy `0.05-0.15` per-image roleplay market). At `16M/$12.99 bundle (0.81/M)` effective `12k/20k` for the pack but charged as `15/25` nominal — the `5x` text margin subsidizes images as retention.

---

## 10. Minimal working examples (copy/paste)

### T2I — Node (fetch) direct
```ts
const workflow = {
  "10":{"inputs":{"vae_name":"qwen_image_vae.safetensors"},"class_type":"VAELoader"},
  "12":{"inputs":{"unet_name":"qwen-rapid-nsfw-v5.3-Q6_K.gguf"},"class_type":"UnetLoaderGGUF"},
  "61":{"inputs":{"clip_name":"Qwen2.5-VL-7B-Instruct-abliterated.Q4_K_M.gguf","type":"qwen_image","device":"default"},"class_type":"CLIPLoaderGGUF"},
  "66":{"inputs":{"shift":3.1,"model":["12",0]},"class_type":"ModelSamplingAuraFlow"},
  "6": {"inputs":{"text":"masterpiece anime, 1girl, long blonde hair","clip":["61",0]},"class_type":"CLIPTextEncode"},
  "7": {"inputs":{"text":" ","clip":["61",0]},"class_type":"CLIPTextEncode"},
  "27":{"inputs":{"width":832,"height":1216,"batch_size":1},"class_type":"EmptySD3LatentImage"},
  "3": {"inputs":{"seed":42,"steps":4,"cfg":1.0,"sampler_name":"euler_ancestral","scheduler":"beta","denoise":1.0,"model":["66",0],"positive":["6",0],"negative":["7",0],"latent_image":["27",0]},"class_type":"KSampler"},
  "8": {"inputs":{"samples":["3",0],"vae":["10",0]},"class_type":"VAEDecode"},
  "9": {"inputs":{"filename_prefix":"ComfyUI","images":["8",0]},"class_type":"SaveImage"}
};
const r = await fetch(`https://api.runpod.ai/v2/${ID}/runsync`, {
  method:"POST",
  headers:{Authorization:`Bearer ${KEY}`, "Content-Type":"application/json"},
  body: JSON.stringify({input:{workflow}})
});
```

### Edit — single ref (with auto-size)
```ts
const b64 = (await fetch(file).then(r=>r.blob()).then(b=> new Promise<string>(res=>{ const fr=new FileReader(); fr.onload=()=>res(fr.result as string); fr.readAsDataURL(b); })));
const workflow = {
  "10":{"inputs":{"vae_name":"qwen_image_vae.safetensors"},"class_type":"VAELoader"},
  "12":{"inputs":{"unet_name":"qwen-rapid-nsfw-v5.3-Q6_K.gguf"},"class_type":"UnetLoaderGGUF"},
  "61":{"inputs":{"clip_name":"Qwen2.5-VL-7B-Instruct-abliterated.Q4_K_M.gguf","type":"qwen_image","device":"default"},"class_type":"CLIPLoaderGGUF"},
  "41":{"inputs":{"image":"ref.png"},"class_type":"LoadImage"},
  "27":{"inputs":{"width":768,"height":1216,"batch_size":1},"class_type":"EmptySD3LatentImage"},
  "66":{"inputs":{"shift":3.1,"model":["12",0]},"class_type":"ModelSamplingAuraFlow"},
  "68":{"inputs":{"prompt":"keep the same girl, same face and outfit, now she offers a box of chocolates with both hands toward viewer","clip":["61",0],"vae":["10",0],"image1":["41",0],"target_latent":["27",0]},"class_type":"TextEncodeQwenImageEditPlus"},
  "69":{"inputs":{"text":" ","clip":["61",0]},"class_type":"CLIPTextEncode"},
  "31":{"inputs":{"seed":297103960,"steps":4,"cfg":1.0,"sampler_name":"euler_ancestral","scheduler":"beta","denoise":1.0,"model":["66",0],"positive":["68",0],"negative":["69",0],"latent_image":["27",0]},"class_type":"KSampler"},
  "8": {"inputs":{"samples":["31",0],"vae":["10",0]},"class_type":"VAEDecode"},
  "9": {"inputs":{"filename_prefix":"ComfyUI","images":["8",0]},"class_type":"SaveImage"}
};
const r2 = await fetch(`https://api.runpod.ai/v2/${ID}/runsync`, {
  method:"POST",
  headers:{Authorization:`Bearer ${KEY}`, "Content-Type":"application/json"},
  body: JSON.stringify({input:{workflow, images:[{name:"ref.png", image:b64}]}})
});
```

### Multi-ref + tagging + auto-size logic (extract)
```ts
// prompt: "@ref1 wears @ref2 on beach" → normalize before workflow build
let prompt = inputPrompt.replace(/@ref1/gi,"Picture 1").replace(/@ref2/gi,"Picture 2").replace(/@ref3/gi,"Picture 3").replace(/@ref4/gi,"Picture 4");
const refs = inputRefs.slice(0,4); // [{name,image}]
const plusInputs: any = { prompt, clip: clipRef, vae: vaeRef, target_latent: ["27",0] };
refs.forEach((r,i)=> plusInputs[`image${i+1}`] = [String(41+i),0]);
// workflow nodes 41..44 each LoadImage.image = refs[i].name
```

### Batch (two strategies) — supabase pseudo
```ts
// 1) batch_size>1 (one call, N images, same prompt)
wf["27"].inputs.batch_size = 3;
// → result output.images.length===3, charge 1*PRICE_* or 3*PRICE_* per policy

// 2) multi-prompt batch (N calls, same refs, different prompts)
const prompts = ["wears outfit A", "wears outfit B", "at beach"] as const;
const results = [];
for(const p of prompts){
  const one = await callRunsync(buildWorkflow({...base, prompt: p}));
  results.push(one); // each cost PRICE_*, charge N*PRICE_* atomically
}
```

---

## 11. Repo map (where each thing lives)

```
darkcoal-qwen-fast/
  handler.py               # RunPod handler: validate_input, upload_images / push to /upload/image, queue_workflow /prompt, WS polling, /history + /view → {images}
  Dockerfile               # base(cuda12.6.3)→ComfyUI 0.29.0→torch cu126→ComfyUI-GGUF→nodes_qwen.v2 patch→yaml validation→quick-test-for-ci; qwen-downloader baked stripped (FAST=skip)
  src/start.sh             # GPU preflight, network-volume check (now /runpod-volume only at a216b4b), gguf check, ComfyUI + handler launch
  src/extra_model_paths.yaml # runpod_worker_comfy: base_path /runpod-volume (plus explicit unet_gguf/clip_gguf); pod compat reverted
  src/network_volume.py    # volume diagnostics (debug gated)
  test_input.json          # canonical txt2img workflow (Phil v53, euler_ancestral/beta, 4 steps, 832x1216, abliterated)
  test_input_edit.json     # canonical edit workflow (Phil v53, Plus with image1+target_latent, 4 steps)
  playground.html          # canonical client: buildWorkflow, buildImagesPayload, polling, auto-size, multi-ref @refN→Picture N, localStorage, presets/loras
  QWEN_FAST_DEEP_DIVE.md   # this doc
  docs/network-volumes.md  # volume docs referenced by plan/start
  .github/workflows/build.yml # CI publish: ghcr.io/alfa-jim/darkcoal-qwen-fast:latest/qwen-image-edit/late2 (all a216b4b) — platform linux/amd64, USE_NETWORK_VOLUME=true
```

Playground defaults and presets worth copying verbatim (qwen note, locked cfg 1/euler_ancestral/beta/denoise 1, EmptySD3Latent+KSampler wiring, negative " ", LoraLoader chain between ModelSamplingAuraFlow and KSampler). Every semantic in the doc maps 1:1 to these files — use them as source of truth if this doc and code diverge, code wins.

---

## 12. Operational gotchas for the assistant's implementation

- **Snap `/64` early** — leaving `width:"768"` as string is fine, but `Number(select value) NaN→0` is the #1 400. Coerce, snap, guard.
- **Data URI prefix** — `data:image/png;base64,` is optional; handler strips. Prefer `data:image/jpeg;base64,` with `quality 0.92` to stay under RunPod body cap when refs are phone photos (~10MB PNG → 2MB JPEG).
- **Serverless cold ~2 min** — first call after idle returns `IN_QUEUE` quickly. Proxy should not 504 on `runsync`; do the `IN_QUEUE→/status` fallback with 600s AbortController and 1.5s poll.
- **Cost & hold** — hold coals before the fetch, commit on `COMPLETED`, refund on any `error/FAILED` (including validation 400) — unless user sent malformed prompt, in which case still refund (UX). Log `delayTime vs executionTime` to catch cold vs warm.
- **PG/Rls** — `generations` insert must include `auth.uid()` row owner; storage objects `gens/<uid>/…` with RLS only-owner read. Never return `data` base64 raw to app in list queries — cap at URLs.
- **Tag semantics** — normalize `@ref1` client-side **and** server-side (the Plus node's tokenizer only understands `Picture 1` literal). Warn if `refs.length==0` but prompt contains `Picture`/`@ref`.
- **Safety** — Rapid-AIO NSFW is uncensored (abliterated clip). Do not proxy to clients expecting safety_checker; your app is the gate (age gate + NSFW toggle) — mark generations with `nsfw:true`.
- **LoRAs** — currently `qwen-anime-irl.safetensors` baked; Supabase doesn't need to ship lora binaries — just write `LoraLoader` nodes referencing `qwen-anime-irl` at `0.8`. Any future `models/loras/*.safetensors` on volume becomes available without image rebuild.

