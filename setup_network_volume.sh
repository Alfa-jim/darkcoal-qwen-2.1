#!/usr/bin/env bash
# setup_network_volume.sh - Populate RunPod Network Volume for darkcoal-qwen-2.1 (Qwen 2.1 GGUF)
# Source of truth: https://huggingface.co/abenzerps/Qwen-Image-2.1-Uncensored-GGUF
# Place in project root. On Pod: volume at /workspace  On Serverless: /runpod-volume
# RunPod mounts the same Network Volume at both paths - this script auto-detects.
#
# Usage:  chmod +x setup_network_volume.sh && ./setup_network_volume.sh
#         ./setup_network_volume.sh --clean   # remove existing and re-download
#         ./setup_network_volume.sh --verify  # only verify, no download
#
# Safe resume: curl -L -C - --retry 5 - re-runs are idempotent, partial files resume.
# Visual: colors, progress bars, size checks, summary table.

set -uo pipefail

# -- Colors & helpers ----------------------------------------------------------
if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
  BOLD=$(tput bold); DIM=$(tput dim); RESET=$(tput sgr0)
  GREEN=$(tput setaf 2); RED=$(tput setaf 1); YELLOW=$(tput setaf 3)
  CYAN=$(tput setaf 6); MAGENTA=$(tput setaf 5); BLUE=$(tput setaf 4)
else
  BOLD=""; DIM=""; RESET=""; GREEN=""; RED=""; YELLOW=""; CYAN=""; MAGENTA=""; BLUE=""
fi
ok()   { echo -e "  ${GREEN}[OK]${RESET} $*"; }
warn() { echo -e "  ${YELLOW}[WARN]${RESET} $*"; }
err()  { echo -e "  ${RED}[FAIL]${RESET} $*"; }
info() { echo -e "  ${CYAN} ->${RESET} $*"; }
step() { echo -e "\n${BOLD}${BLUE}>> $*${RESET}"; }
divider() { echo -e "${DIM}--------------------------------------------------------${RESET}"; }

# -- Args ---------------------------------------------------------------------
CLEAN=0; VERIFY_ONLY=0
for a in "$@"; do case "$a" in --clean) CLEAN=1;; --verify) VERIFY_ONLY=1;; --help|-h) echo "Usage: $0 [--clean] [--verify]"; exit 0;; esac; done

# -- Volume detection (Pod vs Serverless) -------------------------------------
if [ -d "/runpod-volume" ]; then
  VOL_BASE="/runpod-volume"
elif [ -d "/workspace" ]; then
  VOL_BASE="/workspace"
else
  VOL_BASE="/runpod-volume"
  warn "Neither /runpod-volume nor /workspace found - assuming $VOL_BASE (will mkdir)"
fi
MODELS_BASE="$VOL_BASE/models"
VAE_DIR="$MODELS_BASE/vae"
TE_DIR="$MODELS_BASE/text_encoders"
DM_DIR="$MODELS_BASE/diffusion_models"
LORA_DIR="$MODELS_BASE/loras"

echo -e "${BOLD}darkcoal-qwen-2.1 - Network Volume Setup (Qwen 2.1 GGUF - abenzerps UC + pottokao Heretic)${RESET}"
echo -e "${DIM}Volume: $VOL_BASE  |  Models: $MODELS_BASE${RESET}"
divider
echo -e "${DIM}Docs: https://huggingface.co/abenzerps/Qwen-Image-2.1-Uncensored-GGUF${RESET}"
echo -e "${DIM}Default: DiT Q4_K_M UC 4.6GB + Heretic Q4_K_M 4GB + mmproj 1.35GB + VAE bf16 0.68GB = ~10.6GB${RESET}"
echo -e "${DIM}Alt: qwen3vl_8b_int8_convrot.safetensors (9.35GB, Comfy-Org, censored base) via CLIPLoader${RESET}"

# -- HF token (optional, for gated repos) ---------------------------------------
# abenzerps + pottokao + Comfy-Org are PUBLIC, no token needed.
if [ -n "${HF_TOKEN:-}" ]; then
  info "Using HF_TOKEN (auth enabled)"
  AUTH_ARGS=(-H "Authorization: Bearer $HF_TOKEN")
else
  AUTH_ARGS=()
fi

# -- Config -------------------------------------------------------------------
# Filenames match test_input.json expectations (plus canonical HF names as aliases):
#   diffusion_models/qwen-image-2.1-UC-Q4_K_M.gguf           (HF canonical, 4.60GB) + alias qwen-image-2.1-uncensored-Q4_K_M.gguf
#   text_encoders/qwen-image-2.1-text-encoder-uncensored-Q4_K_M.gguf  (Heretic Q4_K_M, 4GB)
#   text_encoders/qwen-image-2.1-text-encoder-uncensored-mmproj-f16.gguf (1.35GB)
#   vae/qwen_image_2.1_vae_bf16.safetensors                  (HF canonical, 676MB) + alias qwen_image_vae.safetensors
# Optional: text_encoders/qwen3vl_8b_int8_convrot.safetensors (HF Comfy-Org, 9.35GB, lower VRAM but censored)
VAE_URL="https://huggingface.co/Comfy-Org/Qwen-Image-2.1/resolve/main/vae/qwen_image_2.1_vae_bf16.safetensors"
# Keep old Comfy converted alias for backward compat (if needed, we symlink)
VAE_ALIAS="qwen_image_vae.safetensors"
TE_Q4_URL="https://huggingface.co/pottokao/Qwen-Image-2.1-Text-Encoder-Heretic-GGUF/resolve/main/qwen3vl_8b_heretic-Q4_K_M.gguf"
MMPROJ_URL="https://huggingface.co/pottokao/Qwen-Image-2.1-Text-Encoder-Heretic-GGUF/resolve/main/mmproj-qwen3vl_8b_heretic-f16.gguf"
DM_Q4_URL="https://huggingface.co/abenzerps/Qwen-Image-2.1-Uncensored-GGUF/resolve/main/qwen-image-2.1-UC-Q4_K_M.gguf"
# Optional Heretic alt quant examples (uncomment to fetch):
# DM_Q6_URL="https://huggingface.co/abenzerps/Qwen-Image-2.1-Uncensored-GGUF/resolve/main/qwen-image-2.1-UC-Q6_K.gguf"
# DM_Q8_URL="https://huggingface.co/abenzerps/Qwen-Image-2.1-Uncensored-GGUF/resolve/main/qwen-image-2.1-UC-Q8_0.gguf"
TE_INT8_URL="https://huggingface.co/Comfy-Org/Qwen-Image-2.1/resolve/main/text_encoders/qwen3vl_8b_int8_convrot.safetensors"

# Minimum valid sizes (bytes) - catches HTML 404 pages (7KB) and truncated files
VAE_MIN=500000000
TE_MIN=3000000000
MMPROJ_MIN=1000000000
DM_MIN=3500000000
TE_INT8_MIN=8000000000

# -- Dirs ---------------------------------------------------------------------
step "1/4 - Preparing directories"
mkdir -p "$VAE_DIR" "$TE_DIR" "$DM_DIR" "$LORA_DIR"
ok "Created $VAE_DIR $TE_DIR $DM_DIR $LORA_DIR"
df -h "$VOL_BASE" 2>&1 | sed 's/^/  /' || true
du -sh "$MODELS_BASE" 2>&1 | sed 's/^/  /' || true

if [ "$CLEAN" = "1" ]; then
  step "CLEAN - removing existing Qwen 2.1 files"
  rm -f "$TE_DIR/qwen-image-2.1-text-encoder-uncensored-Q4_K_M.gguf" \
        "$TE_DIR/qwen-image-2.1-text-encoder-uncensored-mmproj-f16.gguf" \
        "$DM_DIR/qwen-image-2.1-UC-Q4_K_M.gguf" \
        "$DM_DIR/qwen-image-2.1-uncensored-Q4_K_M.gguf" \
        "$VAE_DIR/qwen_image_2.1_vae_bf16.safetensors" \
        "$VAE_DIR/qwen_image_vae.safetensors" \
        "$TE_DIR/qwen3vl_8b_heretic-Q4_K_M.gguf" \
        "$TE_DIR/mmproj-qwen3vl_8b_heretic-f16.gguf" 2>&1 | sed 's/^/  /' || true
  ok "Cleaned - will re-download"
fi

# -- Download helper ----------------------------------------------------------
download_one() {
  local dest="$1" url="$2" min="$3"
  local name
  name=$(basename "$dest")

  if [ -f "$dest" ]; then
    local sz
    sz=$(stat -c%s "$dest" 2>/dev/null || stat -f%z "$dest" 2>/dev/null || echo 0)
    if [ "$sz" -ge "$min" ]; then
      ok "$name already present ($(numfmt --to=iec-i --suffix=B $sz 2>/dev/null || echo "${sz}B") >= $(numfmt --to=iec-i --suffix=B $min 2>/dev/null || echo ${min})B) - skip"
      return 0
    else
      warn "$name present but too small ($sz < $min) - likely HTML/truncated, re-downloading"
      rm -f "$dest"
    fi
  fi

  if [ "$VERIFY_ONLY" = "1" ]; then
    err "$name MISSING (verify only, not downloading)"
    return 1
  fi

  info "Downloading $name"
  echo -e "  ${DIM}-> $url${RESET}"
  echo -e "  ${DIM}-> $dest${RESET}"

  if curl -L -C - --retry 5 --retry-delay 5 \
          --connect-timeout 30 --progress-bar \
          "${AUTH_ARGS[@]}" \
          -o "$dest" "$url"; then
    local sz2
    sz2=$(stat -c%s "$dest" 2>/dev/null || stat -f%z "$dest" 2>/dev/null || echo 0)
    if [ "$sz2" -lt "$min" ]; then
      err "$name downloaded but too small ($sz2 < $min) - check URL or HF lfs"
      ls -lh "$dest" 2>&1 | sed 's/^/  /'
      head -c 500 "$dest" 2>&1 | cat -A | sed 's/^/  /'
      return 1
    fi
    ok "$name done ($(numfmt --to=iec-i --suffix=B $sz2 2>/dev/null || echo ${sz2}B))"
    return 0
  else
    local ec=$?
    err "$name failed (curl exit $ec) - will resume on next run: curl -L -C - -o $dest $url"
    return $ec
  fi
}

# -- Download all -------------------------------------------------------------
step "2/4 - Downloading Qwen 2.1 GGUF (abenzerps + pottokao, safe resume, 5 retries)"
FAIL=0
# VAE - canonical bf16 (676MB) — HF table: vae/qwen_image_2.1_vae_bf16.safetensors
download_one "$VAE_DIR/qwen_image_2.1_vae_bf16.safetensors" "$VAE_URL" "$VAE_MIN" || FAIL=$((FAIL+1))
echo ""
# Back-compat alias: qwen_image_vae.safetensors -> qwen_image_2.1_vae_bf16.safetensors
if [ -f "$VAE_DIR/qwen_image_2.1_vae_bf16.safetensors" ] && [ ! -f "$VAE_DIR/$VAE_ALIAS" ]; then
  ln -sf qwen_image_2.1_vae_bf16.safetensors "$VAE_DIR/$VAE_ALIAS" && info "Created VAE alias $VAE_ALIAS -> qwen_image_2.1_vae_bf16.safetensors"
fi
echo ""
# Heretic text encoder GGUF (uncensored)
download_one "$TE_DIR/qwen-image-2.1-text-encoder-uncensored-Q4_K_M.gguf" "$TE_Q4_URL" "$TE_MIN" || FAIL=$((FAIL+1))
echo ""
download_one "$TE_DIR/qwen-image-2.1-text-encoder-uncensored-mmproj-f16.gguf" "$MMPROJ_URL" "$MMPROJ_MIN" || FAIL=$((FAIL+1))
echo ""
# DiT GGUF - canonical name is UC-Q4_K_M (4.60GB per HF table)
download_one "$DM_DIR/qwen-image-2.1-UC-Q4_K_M.gguf" "$DM_Q4_URL" "$DM_MIN" || FAIL=$((FAIL+1))
echo ""
# Back-compat alias: qwen-image-2.1-uncensored-Q4_K_M.gguf -> qwen-image-2.1-UC-Q4_K_M.gguf (playground/test_input legacy name)
if [ -f "$DM_DIR/qwen-image-2.1-UC-Q4_K_M.gguf" ] && [ ! -f "$DM_DIR/qwen-image-2.1-uncensored-Q4_K_M.gguf" ]; then
  ln -sf qwen-image-2.1-UC-Q4_K_M.gguf "$DM_DIR/qwen-image-2.1-uncensored-Q4_K_M.gguf" && info "Created alias qwen-image-2.1-uncensored-Q4_K_M.gguf -> qwen-image-2.1-UC-Q4_K_M.gguf"
fi
echo ""
# Optional: Comfy-Org int8 text encoder (9.35GB) — uncomment if you want HF recommended lower-VRAM path
# download_one "$TE_DIR/qwen3vl_8b_int8_convrot.safetensors" "$TE_INT8_URL" "$TE_INT8_MIN" || FAIL=$((FAIL+1))
echo "Tip: For HF recommended int8 path (9GB safetensor, swap clip_name to qwen3vl_8b_int8_convrot.safetensors via CLIPLoader):"
echo -e "  ${DIM}curl -L -C - -o $TE_DIR/qwen3vl_8b_int8_convrot.safetensors $TE_INT8_URL${RESET}"
echo ""

# -- Verify -------------------------------------------------------------------
step "3/4 - Verifying"
divider
ALL_OK=1
for entry in "$VAE_DIR/qwen_image_2.1_vae_bf16.safetensors:$VAE_MIN" \
             "$TE_DIR/qwen-image-2.1-text-encoder-uncensored-Q4_K_M.gguf:$TE_MIN" \
             "$TE_DIR/qwen-image-2.1-text-encoder-uncensored-mmproj-f16.gguf:$MMPROJ_MIN" \
             "$DM_DIR/qwen-image-2.1-UC-Q4_K_M.gguf:$DM_MIN"; do
  dest="${entry%%:*}"
  min="${entry##*:}"
  name=$(basename "$dest")
  if [ -f "$dest" ]; then
    sz=$(stat -c%s "$dest" 2>/dev/null || stat -f%z "$dest" 2>/dev/null || echo 0)
    h=$(ls -lh "$dest" 2>&1 | awk '{print $5, $9}')
    if [ "$sz" -ge "$min" ]; then
      echo -e "  ${GREEN}[OK]${RESET} $h  ${DIM}($(numfmt --to=iec-i --suffix=B $sz 2>/dev/null || echo $sz))${RESET}"
    else
      echo -e "  ${RED}[FAIL]${RESET} $h  TOO SMALL (< $(numfmt --to=iec-i --suffix=B $min 2>/dev/null || echo $min)) - re-run script"
      ALL_OK=0
    fi
  else
    echo -e "  ${RED}[FAIL]${RESET} $name  MISSING"
    ALL_OK=0
  fi
done
echo ""
# Check aliases exist
for a in "$VAE_DIR/$VAE_ALIAS" "$DM_DIR/qwen-image-2.1-uncensored-Q4_K_M.gguf"; do
  if [ -L "$a" ] || [ -f "$a" ]; then echo -e "  ${GREEN}[OK]${RESET} alias $(basename $a) -> $(readlink $a 2>/dev/null || echo ok)"; else echo -e "  ${YELLOW}[WARN]${RESET} alias $(basename $a) missing (optional)"; fi
done
echo ""
du -sh "$MODELS_BASE"/* 2>&1 | sed "s/^/  /" || true
echo ""
df -h "$VOL_BASE" 2>&1 | sed 's/^/  /' || true

if [ "$VERIFY_ONLY" = "1" ]; then
  if [ "$ALL_OK" = "1" ]; then ok "Verify OK - all Q4 files present"; else err "Verify FAILED"; fi
  exit $((1-ALL_OK))
fi

# -- Summary ------------------------------------------------------------------
step "4/4 - Summary"
if [ "$FAIL" -gt 0 ] || [ "$ALL_OK" != "1" ]; then
  err "Some files failed ($FAIL) - re-run ./setup_network_volume.sh to resume (curl -C -)"
  echo -e "\n${YELLOW}Tips:${RESET}"
  echo -e "  * Truncated mmproj at 7.7MB = HTML 404 - delete and re-run:"
  echo -e "    ${DIM}rm $TE_DIR/qwen-image-2.1-text-encoder-uncensored-mmproj-f16.gguf && ./setup_network_volume.sh${RESET}"
  echo -e "  * Check volume mount: ${DIM}df -h $VOL_BASE && ls -lh $MODELS_BASE/*/*${RESET}"
  echo -e "  * HF int8 fallback: ${DIM}curl -L -C - -o $TE_DIR/qwen3vl_8b_int8_convrot.safetensors $TE_INT8_URL${RESET}"
  echo -e "  * Heretic = uncensored/abliterated (pottokao + abenzerps, public, no token)"
  exit 1
else
  ok "All Q4 files ready!"
  echo ""
  echo -e "${BOLD}Next:${RESET}"
  echo -e "  1. Set RunPod Serverless endpoint -> Advanced -> Network Volume -> ${CYAN}qwen-2.1-models${RESET} (same region, e.g. CA)"
  echo -e "  2. Deploy ${CYAN}ghcr.io/alfa-jim/darkcoal-qwen-2.1:latest${RESET} (MODEL_TYPE=qwen-2.1, USE_NETWORK_VOLUME=true)"
  echo -e "  3. Test: ${DIM}curl -X POST https://api.runpod.ai/v2/<id>/runsync -H 'Authorization: Bearer \$KEY' -d @test_input.json${RESET}"
  echo ""
  echo -e "${DIM}Extra: For Q6_K (5.88GB) or Q8_0 (7.59GB) just change unet_name in workflow - same volume, swap file via:${RESET}"
  echo -e "${DIM}  curl -L -C - -o $DM_DIR/qwen-image-2.1-UC-Q6_K.gguf https://huggingface.co/abenzerps/Qwen-Image-2.1-Uncensored-GGUF/resolve/main/qwen-image-2.1-UC-Q6_K.gguf${RESET}"
  echo -e "${DIM}  curl -L -C - -o $DM_DIR/qwen-image-2.1-UC-Q8_0.gguf https://huggingface.co/abenzerps/Qwen-Image-2.1-Uncensored-GGUF/resolve/main/qwen-image-2.1-UC-Q8_0.gguf${RESET}"
  echo -e "${DIM}Workflow expects: text_encoders/qwen-image-2.1-text-encoder-uncensored-Q4_K_M.gguf (Heretic) + diffusion_models/qwen-image-2.1-UC-Q4_K_M.gguf + vae/qwen_image_2.1_vae_bf16.safetensors${RESET}"
fi
divider
echo -e "${DIM}RunPod note: /workspace (Pod) and /runpod-volume (Serverless) are same volume - this script auto-detects VOL_BASE${RESET}"
