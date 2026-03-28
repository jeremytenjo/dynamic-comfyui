#!/usr/bin/env bash

# Use libtcmalloc for better memory management
TCMALLOC="$(ldconfig -p | grep -Po "libtcmalloc.so.\d" | head -n 1)"
export LD_PRELOAD="${TCMALLOC}"

# Startup tuning knobs
INSTALL_ONNXRUNTIME_AT_STARTUP="${INSTALL_ONNXRUNTIME_AT_STARTUP:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for handler_file in "$SCRIPT_DIR"/handlers/*.sh; do
    # shellcheck source=/dev/null
    source "$handler_file"
done


if ! which curl > /dev/null 2>&1; then
    curl_start_ts=$(date +%s)
    echo "Installing curl..."
    apt-get update && apt-get install -y curl
    curl_rc=$?
    curl_end_ts=$(date +%s)
    if [ $curl_rc -eq 0 ]; then
        log_boot_timing "package_install" "curl" "success" "$curl_start_ts" "$curl_end_ts" "0" "apt-get"
    else
        log_boot_timing "package_install" "curl" "failed" "$curl_start_ts" "$curl_end_ts" "0" "apt-get"
    fi
else
    echo "curl is already installed"
    curl_now_ts=$(date +%s)
    log_boot_timing "package_install" "curl" "skipped_existing" "$curl_now_ts" "$curl_now_ts" "0" "apt-get"
fi

# Set the network volume path
NETWORK_VOLUME="/workspace"
URL="http://127.0.0.1:8188"

# Check if NETWORK_VOLUME exists; if not, use root directory instead
if [ ! -d "$NETWORK_VOLUME" ]; then
    echo "NETWORK_VOLUME directory '$NETWORK_VOLUME' does not exist. You are NOT using a network volume. Setting NETWORK_VOLUME to '/' (root directory)."
    NETWORK_VOLUME="/"
    echo "NETWORK_VOLUME directory doesn't exist. Starting JupyterLab on root directory..."
    jupyter-lab --ip=0.0.0.0 --allow-root --no-browser --NotebookApp.token='' --NotebookApp.password='' --ServerApp.allow_origin='*' --ServerApp.allow_credentials=True --notebook-dir=/ &
else
    echo "NETWORK_VOLUME directory exists. Starting JupyterLab..."
    jupyter-lab --ip=0.0.0.0 --allow-root --no-browser --NotebookApp.token='' --NotebookApp.password='' --ServerApp.allow_origin='*' --ServerApp.allow_credentials=True --notebook-dir=/workspace &
fi

INSTALL_START_TS=$(date +%s)
mkdir -p "$NETWORK_VOLUME"


COMFYUI_DIR="$NETWORK_VOLUME/ComfyUI"
WORKFLOW_DIR="$NETWORK_VOLUME/ComfyUI/user/default/workflows"
CUSTOM_NODES_DIR="$NETWORK_VOLUME/ComfyUI/custom_nodes"

if [ ! -d "$COMFYUI_DIR" ]; then
    mkdir -p "$NETWORK_VOLUME"
    mv /ComfyUI "$COMFYUI_DIR"
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

if [ "$INSTALL_ONNXRUNTIME_AT_STARTUP" = "1" ]; then
    (
        onnx_start_ts=$(date +%s)
        pip install onnxruntime-gpu
        onnx_rc=$?
        onnx_end_ts=$(date +%s)
        if [ $onnx_rc -eq 0 ]; then
            log_timing "pip_install" "onnxruntime-gpu" "success" "$onnx_start_ts" "$onnx_end_ts" "0" "pip"
        else
            log_timing "pip_install" "onnxruntime-gpu" "failed" "$onnx_start_ts" "$onnx_end_ts" "0" "pip"
        fi
        exit $onnx_rc
    ) &
else
    echo "Skipping runtime onnxruntime-gpu install (INSTALL_ONNXRUNTIME_AT_STARTUP=$INSTALL_ONNXRUNTIME_AT_STARTUP)"
    onnx_now_ts=$(date +%s)
    log_timing "pip_install" "onnxruntime-gpu" "skipped_disabled" "$onnx_now_ts" "$onnx_now_ts" "0" "env:INSTALL_ONNXRUNTIME_AT_STARTUP"
fi


export change_preview_method="true"


# Change to the directory
mkdir -p "$CUSTOM_NODES_DIR"
cd "$CUSTOM_NODES_DIR" || exit 1


echo "Ensuring required custom nodes are installed..."

# Custom Nodes
require_custom_node "was-ns" "was-node-suite-comfyui" "3.0.1"
require_custom_node "comfyui-manager" "ComfyUI-Manager" "3.0.1"
require_custom_node "comfyui-rmbg" "ComfyUI-RMBG" "3.0.0"
require_custom_node "comfyui-inpaint-cropandstitch" "ComfyUI-Inpaint-CropAndStitch" "3.0.10"
require_custom_node "ComfyUI-GGUF" "ComfyUI-GGUF" "1.1.10"
require_custom_node "comfyui-kjnodes" "ComfyUI-KJNodes" "1.3.6"
require_custom_node "comfyui-easy-use" "ComfyUI-Easy-Use" "1.3.6"
require_custom_node "seedvr2_videoupscaler" "ComfyUI-SeedVR2_VideoUpscaler" "2.5.22"
require_custom_node "comfyui_essentials" "ComfyUI_essentials" "1.1.0"


# Function to download a model using huggingface-cli



# Define base paths
# Define base paths (Ensure $NETWORK_VOLUME is set in your environment)
DIFFUSION_MODELS_DIR="$NETWORK_VOLUME/ComfyUI/models/diffusion_models"
TEXT_ENCODERS_DIR="$NETWORK_VOLUME/ComfyUI/models/text_encoders"
VAE_DIR="$NETWORK_VOLUME/ComfyUI/models/vae"
LORAS_DIR="$NETWORK_VOLUME/ComfyUI/models/loras"
CHECKPOINTS_DIR="$NETWORK_VOLUME/ComfyUI/models/checkpoints"
UPSCALE_DIR="$NETWORK_VOLUME/ComfyUI/models/upscale_models"
LATENT_UPSCALE_DIR="$NETWORK_VOLUME/ComfyUI/models/latent_upscale_models"
SEEDVR2_DIR="$NETWORK_VOLUME/ComfyUI/models/SEEDVR2"
SAM3_DIR="$NETWORK_VOLUME/ComfyUI/models/sam3"

echo "📦 Starting model downloads..."

PRIMARY_MODEL_DOWNLOAD_PIDS=()
PRIMARY_MODEL_DOWNLOAD_LABELS=()
MODEL_ID_DOWNLOAD_PIDS=()
MODEL_ID_DOWNLOAD_LABELS=()

# Models
download_model_bg "https://huggingface.co/avatary-ai/files/resolve/main/ae.safetensors" "$VAE_DIR/ae.safetensors"
download_model_bg "https://huggingface.co/avatary-ai/files/resolve/main/qwen_3_4b.safetensors" "$TEXT_ENCODERS_DIR/qwen_3_4b.safetensors"
download_model_bg "https://huggingface.co/avatary-ai/files/resolve/main/Qwen3-4b-Z-Image-Engineer-V4-F16.gguf" "$TEXT_ENCODERS_DIR/Qwen3-4b-Z-Image-Engineer-V4-F16.gguf"
download_model_bg "https://huggingface.co/avatary-ai/files/resolve/main/z_image_bf16.safetensors" "$DIFFUSION_MODELS_DIR/z_image_bf16.safetensors"
download_model_bg "https://huggingface.co/avatary-ai/files/resolve/main/z_image_turbo_bf16.safetensors" "$DIFFUSION_MODELS_DIR/z_image_turbo.safetensors"
download_model_bg "https://huggingface.co/avatary-ai/files/resolve/main/z_image_turbo.safetensors" "$DIFFUSION_MODELS_DIR/z-image-turbo-nsfw.safetensors"
download_model_bg "https://huggingface.co/avatary-ai/files/resolve/main/z_image_vae.safetensors" "$VAE_DIR/z_image_vae.safetensors"
download_model_bg "https://huggingface.co/avatary-ai/files/resolve/main/Z-Image-AbliteratedV1.f16.gguf" "$TEXT_ENCODERS_DIR/Z-Image-AbliteratedV1.f16.gguf"
download_model_bg "https://huggingface.co/avatary-ai/files/resolve/main/Z-Image-AbliteratedV1.f16.safetensors" "$TEXT_ENCODERS_DIR/Z-Image-AbliteratedV1.f16.safetensors"
download_model_bg "https://huggingface.co/avatary-ai/files/resolve/main/seedvr2_ema_7b_fp16.safetensors" "$SEEDVR2_DIR/seedvr2_ema_7b_fp16.safetensors"
download_model_bg "https://huggingface.co/avatary-ai/files/resolve/main/ema_vae_fp16.safetensors" "$SEEDVR2_DIR/ema_vae_fp16.safetensors"
download_model_bg "https://huggingface.co/avatary-ai/files/resolve/main/sam3.pt" "$SAM3_DIR/sam3.pt"

declare -A MODEL_CATEGORIES=(
    ["$NETWORK_VOLUME/ComfyUI/models/checkpoints"]="$CHECKPOINT_IDS_TO_DOWNLOAD"
    ["$NETWORK_VOLUME/ComfyUI/models/loras"]="$LORAS_IDS_TO_DOWNLOAD"
)

# Counter to track background jobs
download_count=0

# Ensure directories exist and schedule downloads in background
for TARGET_DIR in "${!MODEL_CATEGORIES[@]}"; do
    mkdir -p "$TARGET_DIR"
    MODEL_IDS_STRING="${MODEL_CATEGORIES[$TARGET_DIR]}"

    # Skip if the value is the default placeholder
    if [[ "$MODEL_IDS_STRING" == "replace_with_ids" ]]; then
        echo "⏭️  Skipping downloads for $TARGET_DIR (default value detected)"
        continue
    fi

    IFS=',' read -ra MODEL_IDS <<< "$MODEL_IDS_STRING"

    for MODEL_ID in "${MODEL_IDS[@]}"; do
        sleep 1
        echo "Scheduling download: $MODEL_ID to $TARGET_DIR"
        download_model_id_bg "$TARGET_DIR" "$MODEL_ID"
        ((download_count++))
    done
done

echo "Scheduled $download_count downloads in background"


# Ensure the file exists in the current directory before moving it
cd /

if [ "$change_preview_method" == "true" ]; then
    echo "Updating default preview method..."
    sed -i '/id: *'"'"'VHS.LatentPreview'"'"'/,/defaultValue:/s/defaultValue: false/defaultValue: true/' $NETWORK_VOLUME/ComfyUI/custom_nodes/ComfyUI-VideoHelperSuite/web/js/VHS.core.js
    CONFIG_PATH="$NETWORK_VOLUME/ComfyUI/user/default/ComfyUI-Manager"
    CONFIG_FILE="$CONFIG_PATH/config.ini"

# Ensure the directory exists
mkdir -p "$CONFIG_PATH"

# Create the config file if it doesn't exist
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Creating config.ini..."
    cat <<EOL > "$CONFIG_FILE"
[default]
preview_method = auto
git_exe =
use_uv = False
channel_url = https://raw.githubusercontent.com/ltdrdata/ComfyUI-Manager/main
share_option = all
bypass_ssl = False
file_logging = True
component_policy = workflow
update_policy = stable-comfyui
windows_selector_event_loop_policy = False
model_download_by_agent = False
downgrade_blacklist =
security_level = normal
skip_migration_check = False
always_lazy_install = False
network_mode = public
db_mode = cache
EOL
else
    echo "config.ini already exists. Updating preview_method..."
    sed -i 's/^preview_method = .*/preview_method = auto/' "$CONFIG_FILE"
fi
echo "Config file setup complete!"
    echo "Default preview method updated to 'auto'"
else
    echo "Skipping preview method update (change_preview_method is not 'true')."
fi


echo "Enabling Modern Node Design (Nodes 2.0) by default..."
ensure_nodes2_enabled
echo "Modern Node Design (Nodes 2.0) enabled."

# Workspace as main working directory
echo "cd $NETWORK_VOLUME" >> ~/.bashrc



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

# Start ComfyUI

echo "Starting ComfyUI"
COMFY_ARGS=(--listen --enable-manager)

nohup python3 "$NETWORK_VOLUME/ComfyUI/main.py" "${COMFY_ARGS[@]}" > "$NETWORK_VOLUME/comfyui_${RUNPOD_POD_ID}_nohup.log" 2>&1 &

    # Counter for timeout
    counter=0
    max_wait=45

    until curl --silent --fail "$URL" --output /dev/null; do
        if [ $counter -ge $max_wait ]; then
            echo "ComfyUI should be running if not please reach out to Avatary support."
            break
        fi

        echo "🔄  ComfyUI Starting Up... You can view the startup logs here: $NETWORK_VOLUME/comfyui_${RUNPOD_POD_ID}_nohup.log"
        sleep 2
        counter=$((counter + 2))
    done

    # Only show success message if curl succeeded
    if curl --silent --fail "$URL" --output /dev/null; then
        echo "🚀 ComfyUI is UP"
    fi

    sleep infinity
