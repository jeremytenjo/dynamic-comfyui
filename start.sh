#!/usr/bin/env bash

# Use libtcmalloc for better memory management
TCMALLOC="$(ldconfig -p | grep -Po "libtcmalloc.so.\d" | head -n 1)"
export LD_PRELOAD="${TCMALLOC}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for handler_file in "$SCRIPT_DIR"/handlers/*.sh; do
    # shellcheck source=/dev/null
    source "$handler_file"
done

# Set the network volume path
NETWORK_VOLUME="/workspace"
URL="http://127.0.0.1:8188"

prepare_network_volume_and_start_jupyter

export INSTALL_START_TS
INSTALL_START_TS=$(date +%s)
mkdir -p "$NETWORK_VOLUME"

apply_flash_attn_runtime_hotfix 
configure_torch_cuda_allocator

COMFYUI_DIR="$NETWORK_VOLUME/ComfyUI"
CUSTOM_NODES_DIR="$NETWORK_VOLUME/ComfyUI/custom_nodes"

if [ ! -d "$COMFYUI_DIR" ]; then
    mkdir -p "$NETWORK_VOLUME"
    if ! mv /ComfyUI "$COMFYUI_DIR"; then
        echo "Failed to move /ComfyUI into $COMFYUI_DIR"
        exit 1
    fi
else
    echo "Directory already exists, skipping move."
    # Refresh core ComfyUI files from the image on persisted volumes while
    # preserving runtime/user state.
    if [ -d /ComfyUI ]; then
        if command -v rsync > /dev/null 2>&1; then
            rsync -au \
                --exclude 'user/' \
                --exclude 'models/' \
                --exclude 'custom_nodes/' \
                --exclude 'input/' \
                --exclude 'output/' \
                /ComfyUI/ "$COMFYUI_DIR"/
        else
            # Fallback when rsync is unavailable: update existing files in place.
            cp -au /ComfyUI/. "$COMFYUI_DIR"/
        fi
    fi
fi

# Change to the directory
mkdir -p "$CUSTOM_NODES_DIR"
cd "$CUSTOM_NODES_DIR" || exit 1


echo "Ensuring required custom nodes are installed..."

CUSTOM_NODE_SPECS=(
    "was-ns|was-node-suite-comfyui|3.0.1"
    "comfyui-manager|ComfyUI-Manager|3.0.1"
    "comfyui-rmbg|ComfyUI-RMBG|3.0.0"
    "comfyui-inpaint-cropandstitch|ComfyUI-Inpaint-CropAndStitch|3.0.10"
    "ComfyUI-GGUF|ComfyUI-GGUF|1.1.10"
    "comfyui-kjnodes|ComfyUI-KJNodes|1.3.6"
    "comfyui-easy-use|ComfyUI-Easy-Use|1.3.6"
    "seedvr2_videoupscaler|ComfyUI-SeedVR2_VideoUpscaler|2.5.22"
    "comfyui_essentials|ComfyUI_essentials|1.1.0"
)

total_custom_nodes=${#CUSTOM_NODE_SPECS[@]}
custom_node_idx=0
for custom_node_spec in "${CUSTOM_NODE_SPECS[@]}"; do
    IFS='|' read -r cnr_id repo_dir cnr_version <<< "$custom_node_spec"
    custom_node_idx=$((custom_node_idx + 1))
    echo "⬇️ [$custom_node_idx/$total_custom_nodes] Installing $repo_dir"
    require_custom_node "$cnr_id" "$repo_dir" "$cnr_version"
done

# Define base paths
DIFFUSION_MODELS_DIR="$NETWORK_VOLUME/ComfyUI/models/diffusion_models"
TEXT_ENCODERS_DIR="$NETWORK_VOLUME/ComfyUI/models/text_encoders"
VAE_DIR="$NETWORK_VOLUME/ComfyUI/models/vae"
export LORAS_DIR="$NETWORK_VOLUME/ComfyUI/models/loras"
SEEDVR2_DIR="$NETWORK_VOLUME/ComfyUI/models/SEEDVR2"
SAM3_DIR="$NETWORK_VOLUME/ComfyUI/models/sam3"

mkdir -p "$DIFFUSION_MODELS_DIR" "$TEXT_ENCODERS_DIR" "$VAE_DIR" "$LORAS_DIR" "$SEEDVR2_DIR" "$SAM3_DIR"

echo "📦 Starting model downloads..."

export PRIMARY_MODEL_DOWNLOAD_PIDS=()
export PRIMARY_MODEL_DOWNLOAD_LABELS=()

MODEL_SPECS=(
    "https://huggingface.co/avatary-ai/files/resolve/main/ae.safetensors|$VAE_DIR/ae.safetensors"
    "https://huggingface.co/avatary-ai/files/resolve/main/qwen_3_4b.safetensors|$TEXT_ENCODERS_DIR/qwen_3_4b.safetensors"
    "https://huggingface.co/avatary-ai/files/resolve/main/Qwen3-4b-Z-Image-Engineer-V4-F16.gguf|$TEXT_ENCODERS_DIR/Qwen3-4b-Z-Image-Engineer-V4-F16.gguf"
    "https://huggingface.co/avatary-ai/files/resolve/main/z_image_bf16.safetensors|$DIFFUSION_MODELS_DIR/z_image_bf16.safetensors"
    "https://huggingface.co/avatary-ai/files/resolve/main/z_image_turbo_bf16.safetensors|$DIFFUSION_MODELS_DIR/z_image_turbo.safetensors"
    "https://huggingface.co/avatary-ai/files/resolve/main/z_image_turbo.safetensors|$DIFFUSION_MODELS_DIR/z-image-turbo-nsfw.safetensors"
    "https://huggingface.co/avatary-ai/files/resolve/main/z_image_vae.safetensors|$VAE_DIR/z_image_vae.safetensors"
    "https://huggingface.co/avatary-ai/files/resolve/main/Z-Image-AbliteratedV1.f16.gguf|$TEXT_ENCODERS_DIR/Z-Image-AbliteratedV1.f16.gguf"
    "https://huggingface.co/avatary-ai/files/resolve/main/Z-Image-AbliteratedV1.f16.safetensors|$TEXT_ENCODERS_DIR/Z-Image-AbliteratedV1.f16.safetensors"
    "https://huggingface.co/avatary-ai/files/resolve/main/seedvr2_ema_7b_fp16.safetensors|$SEEDVR2_DIR/seedvr2_ema_7b_fp16.safetensors"
    "https://huggingface.co/avatary-ai/files/resolve/main/ema_vae_fp16.safetensors|$SEEDVR2_DIR/ema_vae_fp16.safetensors"
    "https://huggingface.co/avatary-ai/files/resolve/main/sam3.pt|$SAM3_DIR/sam3.pt"
)

total_models=${#MODEL_SPECS[@]}
model_idx=0
for model_spec in "${MODEL_SPECS[@]}"; do
    IFS='|' read -r model_url model_path <<< "$model_spec"
    model_idx=$((model_idx + 1))
    echo "⬇️ [$model_idx/$total_models] Queueing $(basename "$model_path")"
    download_model_bg "$model_url" "$model_path"
done

# Ensure the file exists in the current directory before moving it
cd /

echo "Renaming loras downloaded as zip files to safetensors files"

if ! finalize_model_downloads; then
    echo "Model installation failed; refusing to start ComfyUI."
    exit 1
fi


if ! ensure_required_text_encoders; then
    echo "Text encoder preflight failed; refusing to start ComfyUI."
    exit 1
fi


if ! ensure_required_vae_models; then
    echo "VAE preflight failed; refusing to start ComfyUI."
    exit 1
fi

if ! ensure_manager_runtime_ready; then
    echo "ComfyUI manager runtime setup failed; refusing to start ComfyUI with --enable-manager."
    exit 1
fi

# Start ComfyUI

echo "Starting ComfyUI"
COMFY_ARGS=(--listen --enable-manager --disable-cuda-malloc)
COMFY_LOG_PATH="$NETWORK_VOLUME/comfyui_${RUNPOD_POD_ID}_nohup.log"

nohup python3 "$NETWORK_VOLUME/ComfyUI/main.py" "${COMFY_ARGS[@]}" > "$COMFY_LOG_PATH" 2>&1 &
COMFY_PID=$!

    # Counter for timeout
    counter=0
    max_wait=45

    until curl --silent --fail "$URL" --output /dev/null; do
        if [ $counter -ge $max_wait ]; then
            echo "ComfyUI failed to become ready within ${max_wait}s. Check logs at $COMFY_LOG_PATH"
            if kill -0 "$COMFY_PID" 2>/dev/null; then
                kill "$COMFY_PID" 2>/dev/null || true
            fi
            exit 1
        fi

        echo "🔄  ComfyUI Starting Up... You can view the startup logs here: $COMFY_LOG_PATH"
        sleep 2
        counter=$((counter + 2))
    done

    # Only show success message if curl succeeded
    if curl --silent --fail "$URL" --output /dev/null; then
        echo "🚀 ComfyUI is UP"
    fi

    sleep infinity
