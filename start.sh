#!/usr/bin/env bash

# Use libtcmalloc for better memory management
TCMALLOC="$(ldconfig -p | grep -Po "libtcmalloc.so.\d" | head -n 1)"
export LD_PRELOAD="${TCMALLOC}"


if ! which aria2 > /dev/null 2>&1; then
    echo "Installing aria2..."
    apt-get update && apt-get install -y aria2
else
    echo "aria2 is already installed"
fi

if ! which curl > /dev/null 2>&1; then
    echo "Installing curl..."
    apt-get update && apt-get install -y curl
else
    echo "curl is already installed"
fi

# Start SageAttention build in the background (optional)
ENABLE_SAGE_ATTENTION="${ENABLE_SAGE_ATTENTION:-1}"
SAGE_PID=""
rm -f /tmp/sage_build_done /tmp/sage_build_failed
if [ "$ENABLE_SAGE_ATTENTION" = "1" ]; then
    echo "Starting SageAttention build..."
    (
        set -euo pipefail
        export EXT_PARALLEL=4 NVCC_APPEND_FLAGS="--threads 8" MAX_JOBS=32
        cd /tmp
        rm -rf SageAttention
        git clone --depth 1 https://github.com/thu-ml/SageAttention.git
        cd SageAttention
        git fetch --depth 1 origin 68de379
        git checkout 68de379
        pip install -e .
        touch /tmp/sage_build_done
    ) > /tmp/sage_build.log 2>&1 || touch /tmp/sage_build_failed &
    SAGE_PID=$!
    echo "SageAttention build started in background (PID: $SAGE_PID)"
else
    echo "Skipping SageAttention build (ENABLE_SAGE_ATTENTION=${ENABLE_SAGE_ATTENTION})."
fi

# Set the network volume path
NETWORK_VOLUME="${NETWORK_VOLUME:-/workspace}"
COMFYUI_PORT="${COMFYUI_PORT:-8188}"
URL="http://127.0.0.1:${COMFYUI_PORT}"
BOOT_START_TS="$(date +%s)"
LAST_STAGE_TS="$BOOT_START_TS"
STARTUP_VOLUME_SEED_MODE="n/a"

mark_stage() {
    local stage_name="$1"
    local now_ts
    now_ts="$(date +%s)"
    local step_elapsed=$((now_ts - LAST_STAGE_TS))
    local total_elapsed=$((now_ts - BOOT_START_TS))
    echo "[timing] stage=${stage_name} step_s=${step_elapsed} total_s=${total_elapsed}"
    LAST_STAGE_TS="$now_ts"
}

# Polling and log-throttle intervals to keep startup output readable.
POLL_INTERVAL_S=5
LOG_INTERVAL_S=30

# Check if NETWORK_VOLUME exists; if not, use root directory instead
if [ ! -d "$NETWORK_VOLUME" ]; then
    echo "NETWORK_VOLUME directory '$NETWORK_VOLUME' does not exist. You are NOT using a network volume. Setting NETWORK_VOLUME to '/' (root directory)."
    NETWORK_VOLUME="/"
fi

STARTUP_TIMING_LOG="$NETWORK_VOLUME/startup_timing.log"
if [ "$NETWORK_VOLUME" = "/" ]; then
    STARTUP_TIMING_LOG="/tmp/startup_timing.log"
fi

mark_stage "volume_detected"

# Optionally skip Jupyter when the base Runpod service already starts it.
if [ "${START_JUPYTER:-1}" = "1" ]; then
    if [ "$NETWORK_VOLUME" = "/" ]; then
        echo "NETWORK_VOLUME directory doesn't exist. Starting JupyterLab on root directory..."
        jupyter-lab --ip=0.0.0.0 --allow-root --no-browser --NotebookApp.token='' --NotebookApp.password='' --ServerApp.allow_origin='*' --ServerApp.allow_credentials=True --notebook-dir=/ &
    else
        echo "NETWORK_VOLUME directory exists. Starting JupyterLab..."
        jupyter-lab --ip=0.0.0.0 --allow-root --no-browser --NotebookApp.token='' --NotebookApp.password='' --ServerApp.allow_origin='*' --ServerApp.allow_credentials=True --notebook-dir=/workspace &
    fi
else
    echo "Skipping JupyterLab startup in template script (START_JUPYTER=${START_JUPYTER})."
fi

mark_stage "jupyter_startup"

COMFYUI_DIR="$NETWORK_VOLUME/ComfyUI"
WORKFLOW_DIR="$NETWORK_VOLUME/ComfyUI/user/default/workflows"

# Set the target directory
CUSTOM_NODES_DIR="$NETWORK_VOLUME/ComfyUI/custom_nodes"

if [ "$NETWORK_VOLUME" = "/" ]; then
    COMFYUI_DIR="/ComfyUI"
    STARTUP_VOLUME_SEED_MODE="ephemeral"
else
    # Keep ComfyUI state on the network volume and seed files once.
    mkdir -p "$COMFYUI_DIR"
    BOOTSTRAP_MARKER="$COMFYUI_DIR/.image_seeded"
    if [ "${FORCE_SYNC_TEMPLATE:-0}" = "1" ]; then
        STARTUP_VOLUME_SEED_MODE="force-sync"
        cp -an /ComfyUI/. "$COMFYUI_DIR"/
        touch "$BOOTSTRAP_MARKER"
    elif [ ! -f "$BOOTSTRAP_MARKER" ]; then
        STARTUP_VOLUME_SEED_MODE="cold-seed"
        cp -an /ComfyUI/. "$COMFYUI_DIR"/
        touch "$BOOTSTRAP_MARKER"
    else
        STARTUP_VOLUME_SEED_MODE="warm-reuse"
    fi
fi

WORKFLOW_DIR="$COMFYUI_DIR/user/default/workflows"
CUSTOM_NODES_DIR="$COMFYUI_DIR/custom_nodes"

mark_stage "comfyui_seed"

pip install onnxruntime-gpu &


export change_preview_method="true"


# Change to the directory
cd "$CUSTOM_NODES_DIR" || exit 1

# Function to download a model using huggingface-cli
download_model() {
    local url="$1"
    local full_path="$2"

    local destination_dir=$(dirname "$full_path")
    local destination_file=$(basename "$full_path")

    mkdir -p "$destination_dir"

    # Simple corruption check: file < 10MB or .aria2 files
    if [ -f "$full_path" ]; then
        local size_bytes=$(stat -f%z "$full_path" 2>/dev/null || stat -c%s "$full_path" 2>/dev/null || echo 0)
        local size_mb=$((size_bytes / 1024 / 1024))

        if [ "$size_bytes" -lt 10485760 ]; then  # Less than 10MB
            echo "🗑️  Deleting corrupted file (${size_mb}MB < 10MB): $full_path"
            rm -f "$full_path"
        else
            echo "✅ $destination_file already exists (${size_mb}MB), skipping download."
            return 0
        fi
    fi

    # Check for and remove .aria2 control files
    if [ -f "${full_path}.aria2" ]; then
        echo "🗑️  Deleting .aria2 control file: ${full_path}.aria2"
        rm -f "${full_path}.aria2"
        rm -f "$full_path"  # Also remove any partial file
    fi

    echo "📥 Downloading $destination_file to $destination_dir..."

    # Download without falloc (since it's not supported in your environment)
    aria2c -x 16 -s 16 -k 1M --continue=true -d "$destination_dir" -o "$destination_file" "$url" &

    echo "Download started in background for $destination_file"
}

# Define base paths
# Define base paths (Ensure $NETWORK_VOLUME is set in your environment)
DIFFUSION_MODELS_DIR="$NETWORK_VOLUME/ComfyUI/models/diffusion_models"
TEXT_ENCODERS_DIR="$NETWORK_VOLUME/ComfyUI/models/text_encoders"
VAE_DIR="$NETWORK_VOLUME/ComfyUI/models/vae"
LORAS_DIR="$NETWORK_VOLUME/ComfyUI/models/loras"
CHECKPOINTS_DIR="$NETWORK_VOLUME/ComfyUI/models/checkpoints"
UPSCALE_DIR="$NETWORK_VOLUME/ComfyUI/models/upscale_models"
LATENT_UPSCALE_DIR="$NETWORK_VOLUME/ComfyUI/models/latent_upscale_models"
SAMS_DIR="$NETWORK_VOLUME/ComfyUI/models/sams"
ULTRALYTICS_BBOX_DIR="$NETWORK_VOLUME/ComfyUI/models/ultralytics/bbox"

echo "📦 Starting model downloads..."

download_model "https://huggingface.co/dci05049/spicy-sdxl/resolve/main/lustify_endgame.safetensors" "$CHECKPOINTS_DIR/lustify_endgame.safetensors"
download_model "https://huggingface.co/dci05049/spicy-sdxl/resolve/main/lustify-ggpwp.safetensors" "$CHECKPOINTS_DIR/lustify-ggpwp.safetensors"
download_model "https://huggingface.co/dci05049/spicy-sdxl/resolve/main/lustify_olt.safetensors" "$CHECKPOINTS_DIR/lustify_olt.safetensors"
download_model "https://huggingface.co/dci05049/spicy-sdxl/resolve/main/pony_diffusion_v6.safetensors" "$CHECKPOINTS_DIR/pony_diffusion_v6.safetensors"
download_model "https://huggingface.co/dci05049/spicy-sdxl/resolve/main/1x-ITF-SkinDiffDetail-Lite-v1.pth" "$UPSCALE_DIR/1x-ITF-SkinDiffDetail-Lite-v1.pth"
download_model "https://huggingface.co/dci05049/spicy-sdxl/resolve/main/1xSkinContrast-High-SuperUltraCompact.pth" "$UPSCALE_DIR/1xSkinContrast-High-SuperUltraCompact.pth"
download_model "https://huggingface.co/dci05049/spicy-sdxl/resolve/main/4xNMKDSuperscale_4xNMKDSuperscale.pt" "$UPSCALE_DIR/4xNMKDSuperscale_4xNMKDSuperscale.pt"
download_model "https://huggingface.co/dci05049/spicy-sdxl/resolve/main/dmd2_sdxl_4step_lora.safetensors" "$LORAS_DIR/dmd2_sdxl_4step_lora.safetensors"
download_model "https://huggingface.co/dci05049/spicy-sdxl/resolve/main/leak_core.safetensors" "$LORAS_DIR/leak_core.safetensors"
download_model "https://huggingface.co/dci05049/spicy-sdxl/resolve/main/breast_size_slider.safetensors" "$LORAS_DIR/breast_size_slider.safetensors"
download_model "https://huggingface.co/dci05049/spicy-sdxl/resolve/main/bresat_sag_slider.safetensors" "$LORAS_DIR/bresat_sag_slider.safetensors"
download_model "https://huggingface.co/dci05049/spicy-sdxl/resolve/main/waist_slider_xl.safetensors" "$LORAS_DIR/waist_slider_xl.safetensors"
download_model "https://huggingface.co/dci05049/spicy-sdxl/resolve/main/leak_core.safetensors" "$LORAS_DIR/leak_core.safetensors"

# Impact Pack defaults required by SAMLoader and UltralyticsDetectorProvider workflows.
download_model "https://dl.fbaipublicfiles.com/segment_anything/sam_vit_b_01ec64.pth" "$SAMS_DIR/sam_vit_b_01ec64.pth"
download_model "https://huggingface.co/Bingsu/adetailer/resolve/main/face_yolov8m.pt" "$ULTRALYTICS_BBOX_DIR/face_yolov8m.pt"


# Keep checking until no aria2c processes are running
download_wait_elapsed=0
while pgrep -x "aria2c" > /dev/null; do
    if [ $((download_wait_elapsed % LOG_INTERVAL_S)) -eq 0 ]; then
        echo "Models are downloading (in progress)..."
    fi
    sleep "$POLL_INTERVAL_S"
    download_wait_elapsed=$((download_wait_elapsed + POLL_INTERVAL_S))
done

mark_stage "baseline_model_downloads"

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
        (cd "$TARGET_DIR" && download_with_aria.py -m "$MODEL_ID") &
        ((download_count++))
    done
done

echo "Scheduled $download_count downloads in background"

# Wait for all downloads to complete
echo "Waiting for downloads to complete..."
optional_download_wait_elapsed=0
while pgrep -x "aria2c" > /dev/null; do
    if [ $((optional_download_wait_elapsed % LOG_INTERVAL_S)) -eq 0 ]; then
        echo "LoRA downloads still in progress..."
    fi
    sleep "$POLL_INTERVAL_S"
    optional_download_wait_elapsed=$((optional_download_wait_elapsed + POLL_INTERVAL_S))
done

mark_stage "optional_model_downloads"


echo "All models downloaded successfully"

echo "All downloads completed"

# Ensure the file exists in the current directory before moving it
cd /

if [ "$change_preview_method" == "true" ]; then
    echo "Updating default preview method..."
    VHS_CORE_JS="$COMFYUI_DIR/custom_nodes/ComfyUI-VideoHelperSuite/web/js/VHS.core.js"
    if [ -f "$VHS_CORE_JS" ]; then
        sed -i '/id: *'"'"'VHS.LatentPreview'"'"'/,/defaultValue:/s/defaultValue: false/defaultValue: true/' "$VHS_CORE_JS"
    else
        echo "ComfyUI-VideoHelperSuite not found; skipping VHS preview patch."
    fi
    CONFIG_PATH="$COMFYUI_DIR/user/default/ComfyUI-Manager"
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

mark_stage "preview_and_manager_config"

# Workspace as main working directory
if ! grep -Fq "cd $NETWORK_VOLUME" ~/.bashrc; then
    echo "cd $NETWORK_VOLUME" >> ~/.bashrc
fi



echo "Renaming loras downloaded as zip files to safetensors files"
cd $LORAS_DIR
for file in *.zip; do
    [ -f "$file" ] || continue
    mv "$file" "${file%.zip}.safetensors"
done

mark_stage "lora_rename"

# Wait for SageAttention build to complete and only enable it if import works.
SAGE_ATTENTION_READY=0
if [ "$ENABLE_SAGE_ATTENTION" = "1" ]; then
    echo "Waiting for SageAttention build to complete..."
    sage_wait_elapsed=0
    while true; do
        if [ -f /tmp/sage_build_done ]; then
            break
        fi
        if [ -f /tmp/sage_build_failed ]; then
            break
        fi
        if [ -n "$SAGE_PID" ] && ! ps -p "$SAGE_PID" > /dev/null 2>&1; then
            touch /tmp/sage_build_failed
            break
        fi
        if [ $((sage_wait_elapsed % LOG_INTERVAL_S)) -eq 0 ]; then
            echo "SageAttention build in progress..."
        fi
        sleep "$POLL_INTERVAL_S"
        sage_wait_elapsed=$((sage_wait_elapsed + POLL_INTERVAL_S))
    done

    if [ -f /tmp/sage_build_done ] && python3 - <<'PY' >/dev/null 2>&1
import sageattention  # noqa: F401
PY
    then
        SAGE_ATTENTION_READY=1
        echo "✅ SageAttention is installed and enabled."
    else
        echo "⚠️  SageAttention is unavailable. ComfyUI will start without --use-sage-attention."
        echo "See /tmp/sage_build.log for details."
    fi
fi

mark_stage "sageattention"

# Wait for CUDA to become available before launching ComfyUI.
wait_for_cuda_ready() {
    local timeout_s="${GPU_READY_TIMEOUT_S:-180}"
    local poll_s="${GPU_READY_POLL_S:-5}"
    local elapsed_s=0
    local log_interval_s=30

    echo "Checking CUDA readiness (timeout=${timeout_s}s, poll=${poll_s}s)..."

    while [ "$elapsed_s" -lt "$timeout_s" ]; do
        if python3 - <<'PY' >/dev/null 2>&1
import torch
ok = torch.cuda.is_available() and torch.cuda.device_count() > 0
if ok:
    _ = torch.cuda.current_device()
raise SystemExit(0 if ok else 1)
PY
        then
            echo "CUDA is ready."
            return 0
        fi

        if [ $((elapsed_s % log_interval_s)) -eq 0 ]; then
            echo "Waiting for CUDA/GPU runtime to initialize..."
            if command -v nvidia-smi >/dev/null 2>&1; then
                nvidia-smi -L 2>/dev/null || true
            fi
        fi

        sleep "$poll_s"
        elapsed_s=$((elapsed_s + poll_s))
    done

    echo "⚠️  CUDA was not ready after ${timeout_s}s. Continuing startup; ComfyUI may fail if GPU runtime is unavailable."
    return 1
}

if [ "${WAIT_FOR_CUDA_READY:-1}" = "1" ]; then
    wait_for_cuda_ready || true
    mark_stage "cuda_ready_wait"
fi

# Start ComfyUI

echo "Starting ComfyUI"

COMFY_LOG_PATH="$NETWORK_VOLUME/comfyui_${RUNPOD_POD_ID}_nohup.log"
COMFY_CMD=(python3 "$COMFYUI_DIR/main.py" --listen "0.0.0.0" --port "$COMFYUI_PORT")
if [ "$SAGE_ATTENTION_READY" = "1" ]; then
    COMFY_CMD+=(--use-sage-attention)
fi

nohup "${COMFY_CMD[@]}" > "$COMFY_LOG_PATH" 2>&1 &
COMFY_PID=$!

# Counter for timeout
counter=0
max_wait=90
comfy_status_log_interval=10

until curl --silent --fail "$URL" --output /dev/null; do
    if ! ps -p "$COMFY_PID" > /dev/null 2>&1; then
        echo "❌ ComfyUI process exited before becoming ready."
        echo "Last 120 lines from $COMFY_LOG_PATH:"
        tail -n 120 "$COMFY_LOG_PATH" || true
        exit 1
    fi

    if [ $counter -ge $max_wait ]; then
        echo "❌ ComfyUI did not become reachable at $URL within ${max_wait}s."
        echo "Last 120 lines from $COMFY_LOG_PATH:"
        tail -n 120 "$COMFY_LOG_PATH" || true
        exit 1
    fi

    if [ $((counter % comfy_status_log_interval)) -eq 0 ]; then
        echo "ComfyUI starting up... logs: $COMFY_LOG_PATH"
    fi
    sleep 2
    counter=$((counter + 2))
done

echo "🚀 ComfyUI is UP"

BOOT_END_TS="$(date +%s)"
BOOT_TOTAL_S=$((BOOT_END_TS - BOOT_START_TS))
BOOT_TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
printf "%s pod=%s volume=%s seed=%s total_s=%s\n" \
    "$BOOT_TIMESTAMP" "${RUNPOD_POD_ID:-unknown}" "$NETWORK_VOLUME" "$STARTUP_VOLUME_SEED_MODE" "$BOOT_TOTAL_S" \
    | tee -a "$STARTUP_TIMING_LOG"
echo "[timing] log_file=$STARTUP_TIMING_LOG"

sleep infinity
