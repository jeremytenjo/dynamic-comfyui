#!/usr/bin/env bash

# Use libtcmalloc for better memory management
TCMALLOC="$(ldconfig -p | grep -Po "libtcmalloc.so.\d" | head -n 1)"
export LD_PRELOAD="${TCMALLOC}"

# Startup tuning knobs
USE_SAGE_ATTENTION="${USE_SAGE_ATTENTION:-0}"
INSTALL_ONNXRUNTIME_AT_STARTUP="${INSTALL_ONNXRUNTIME_AT_STARTUP:-0}"

normalize_cuda_visibility() {
    # Keep CUDA visibility stable before any Python/Torch process starts.
    # Invalid values like "all"/"void"/"none" can trigger CUDA init failures.
    local current="${CUDA_VISIBLE_DEVICES:-}"
    case "${current,,}" in
        "" )
            ;;
        "all"|"none"|"void"|"no"|"null" )
            echo "⚠️  CUDA_VISIBLE_DEVICES='$current' is not valid for CUDA runtime; unsetting it."
            unset CUDA_VISIBLE_DEVICES
            ;;
        * )
            ;;
    esac
}

cuda_preflight_ok() {
    python3 - <<'PY'
import sys
try:
    import torch
    if not torch.cuda.is_available():
        raise RuntimeError("torch.cuda.is_available() returned False")
    _ = torch.cuda.current_device()
    print("CUDA preflight passed")
except Exception as e:
    print(f"CUDA preflight failed: {e}", file=sys.stderr)
    sys.exit(1)
PY
}

normalize_cuda_visibility

BOOT_TIMING_LOG="/tmp/install_bootstrap_timing.log"
echo "filepath_or_filename, duration seconds/minutes, size" > "$BOOT_TIMING_LOG"

log_boot_timing() {
    local phase="$1"
    local part="$2"
    local status="$3"
    local start_ts="$4"
    local end_ts="$5"
    local bytes="$6"
    local source="$7"
    local duration=$((end_ts - start_ts))
    local duration_label
    if [ "$duration" -lt 60 ]; then
        duration_label="${duration}s"
    else
        duration_label="$(awk "BEGIN { printf \"%.2fm\", $duration/60 }")"
    fi
    local size_label
    if [[ "$bytes" =~ ^[0-9]+$ ]]; then
        if [ "$bytes" -ge 1073741824 ]; then
            size_label="$(awk "BEGIN { printf \"%.2f GB\", $bytes/1073741824 }")"
        elif [ "$bytes" -ge 1048576 ]; then
            size_label="$(awk "BEGIN { printf \"%.2f MB\", $bytes/1048576 }")"
        elif [ "$bytes" -ge 1024 ]; then
            size_label="$(awk "BEGIN { printf \"%.2f KB\", $bytes/1024 }")"
        else
            size_label="${bytes} B"
        fi
    else
        size_label="$bytes"
    fi
    local item_label
    item_label="$part"
    if [[ "$source" == /* ]]; then
        item_label="$source"
    fi
    printf "%s, %s, %s\n" "$item_label" "$duration_label" "$size_label" >> "$BOOT_TIMING_LOG"
}


if ! which aria2 > /dev/null 2>&1; then
    aria2_start_ts=$(date +%s)
    echo "Installing aria2..."
    apt-get update && apt-get install -y aria2
    aria2_rc=$?
    aria2_end_ts=$(date +%s)
    if [ $aria2_rc -eq 0 ]; then
        log_boot_timing "package_install" "aria2" "success" "$aria2_start_ts" "$aria2_end_ts" "0" "apt-get"
    else
        log_boot_timing "package_install" "aria2" "failed" "$aria2_start_ts" "$aria2_end_ts" "0" "apt-get"
    fi
else
    echo "aria2 is already installed"
    aria2_now_ts=$(date +%s)
    log_boot_timing "package_install" "aria2" "skipped_existing" "$aria2_now_ts" "$aria2_now_ts" "0" "apt-get"
fi

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

SAGE_PID=""
SAGE_BUILD_START_TS=""
if [ "$USE_SAGE_ATTENTION" = "1" ]; then
    # Start SageAttention build in the background
    SAGE_BUILD_START_TS=$(date +%s)
    echo "Starting SageAttention build..."
    (
        export EXT_PARALLEL=4 NVCC_APPEND_FLAGS="--threads 8" MAX_JOBS=32
        cd /tmp
        git clone https://github.com/thu-ml/SageAttention.git
        cd SageAttention
        git reset --hard 68de379
        pip install -e .
        echo "SageAttention build completed" > /tmp/sage_build_done
    ) > /tmp/sage_build.log 2>&1 &
    SAGE_PID=$!
    echo "SageAttention build started in background (PID: $SAGE_PID)"
else
    echo "Skipping SageAttention build (USE_SAGE_ATTENTION=$USE_SAGE_ATTENTION)"
    sage_now_ts=$(date +%s)
    log_boot_timing "build" "sageattention" "skipped_disabled" "$sage_now_ts" "$sage_now_ts" "0" "env:USE_SAGE_ATTENTION"
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

TIMING_LOG="$NETWORK_VOLUME/install_timing.log"
INSTALL_START_TS=$(date +%s)
mkdir -p "$NETWORK_VOLUME"
echo "filepath_or_filename, duration seconds/minutes, size" > "$TIMING_LOG"

log_timing() {
    local phase="$1"
    local part="$2"
    local status="$3"
    local start_ts="$4"
    local end_ts="$5"
    local bytes="$6"
    local source="$7"
    local duration=$((end_ts - start_ts))
    local duration_label
    if [ "$duration" -lt 60 ]; then
        duration_label="${duration}s"
    else
        duration_label="$(awk "BEGIN { printf \"%.2fm\", $duration/60 }")"
    fi
    local size_label
    if [[ "$bytes" =~ ^[0-9]+$ ]]; then
        if [ "$bytes" -ge 1073741824 ]; then
            size_label="$(awk "BEGIN { printf \"%.2f GB\", $bytes/1073741824 }")"
        elif [ "$bytes" -ge 1048576 ]; then
            size_label="$(awk "BEGIN { printf \"%.2f MB\", $bytes/1048576 }")"
        elif [ "$bytes" -ge 1024 ]; then
            size_label="$(awk "BEGIN { printf \"%.2f KB\", $bytes/1024 }")"
        else
            size_label="${bytes} B"
        fi
    else
        size_label="$bytes"
    fi
    local item_label
    item_label="$part"
    if [[ "$source" == /* ]]; then
        item_label="$source"
    fi
    printf "%s, %s, %s\n" "$item_label" "$duration_label" "$size_label" >> "$TIMING_LOG"
}

if [ -f "$BOOT_TIMING_LOG" ]; then
    tail -n +2 "$BOOT_TIMING_LOG" >> "$TIMING_LOG"
fi

COMFYUI_DIR="$NETWORK_VOLUME/ComfyUI"
WORKFLOW_DIR="$NETWORK_VOLUME/ComfyUI/user/default/workflows"
FACE_SWAP_INPUT_DIR="$NETWORK_VOLUME/ComfyUI/face-swap-these"

# Set the target directory
CUSTOM_NODES_DIR="$NETWORK_VOLUME/ComfyUI/custom_nodes"

if [ ! -d "$COMFYUI_DIR" ]; then
    mkdir -p "$NETWORK_VOLUME"
    mv /ComfyUI "$COMFYUI_DIR"
else
    echo "Directory already exists, skipping move."
    # Ensure missing base folders from image are present on persisted volumes.
    if [ -d /ComfyUI ]; then
        cp -an /ComfyUI/. "$COMFYUI_DIR"/
    fi
fi

# Ensure workflow input folder exists for Load Image Batch in Head-Swap-V1.
mkdir -p "$FACE_SWAP_INPUT_DIR"

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

install_or_update_custom_node() {
    local repo_url="$1"
    local repo_dir="$2"
    local node_path="$CUSTOM_NODES_DIR/$repo_dir"
    local start_ts
    local end_ts
    local rc=0
    start_ts=$(date +%s)

    if [ -d "$node_path/.git" ]; then
        echo "Updating custom node: $repo_dir"
        git -C "$node_path" pull --ff-only || rc=$?
        end_ts=$(date +%s)
        if [ $rc -eq 0 ]; then
            log_timing "custom_node_install" "$repo_dir" "updated" "$start_ts" "$end_ts" "0" "$repo_url"
        else
            log_timing "custom_node_install" "$repo_dir" "update_failed" "$start_ts" "$end_ts" "0" "$repo_url"
            return $rc
        fi
    else
        echo "Installing custom node: $repo_dir"
        git clone --depth 1 "$repo_url" "$node_path" || rc=$?
        end_ts=$(date +%s)
        if [ $rc -eq 0 ]; then
            log_timing "custom_node_install" "$repo_dir" "installed" "$start_ts" "$end_ts" "0" "$repo_url"
        else
            log_timing "custom_node_install" "$repo_dir" "install_failed" "$start_ts" "$end_ts" "0" "$repo_url"
            return $rc
        fi
    fi

    # Install custom node dependencies when provided by the node repo.
    if [ -f "$node_path/requirements.txt" ]; then
        local dep_start_ts
        local dep_end_ts
        dep_start_ts=$(date +%s)
        pip install -r "$node_path/requirements.txt"
        rc=$?
        dep_end_ts=$(date +%s)
        if [ $rc -eq 0 ]; then
            log_timing "custom_node_deps" "$repo_dir" "success" "$dep_start_ts" "$dep_end_ts" "0" "$node_path/requirements.txt"
        else
            log_timing "custom_node_deps" "$repo_dir" "failed" "$dep_start_ts" "$dep_end_ts" "0" "$node_path/requirements.txt"
            return $rc
        fi
    else
        local dep_now_ts
        dep_now_ts=$(date +%s)
        log_timing "custom_node_deps" "$repo_dir" "skipped_no_requirements" "$dep_now_ts" "$dep_now_ts" "0" "$node_path"
    fi

    return 0
}

echo "Ensuring required custom nodes are installed..."
require_custom_node() {
    local repo_url="$1"
    local repo_dir="$2"
    if ! install_or_update_custom_node "$repo_url" "$repo_dir"; then
        local end_ts
        end_ts=$(date +%s)
        echo "❌ Required custom node install/update failed: $repo_dir"
        log_timing "custom_node_install" "$repo_dir" "required_failed_abort" "$INSTALL_START_TS" "$end_ts" "0" "$repo_url"
        exit 1
    fi
}

require_custom_node "https://github.com/ltdrdata/was-node-suite-comfyui.git" "was-node-suite-comfyui"
require_custom_node "https://github.com/ltdrdata/ComfyUI-Manager.git" "ComfyUI-Manager"
require_custom_node "https://github.com/1038lab/ComfyUI-RMBG.git" "ComfyUI-RMBG"
require_custom_node "https://github.com/lquesada/ComfyUI-Inpaint-CropAndStitch.git" "ComfyUI-Inpaint-CropAndStitch"
require_custom_node "https://github.com/city96/ComfyUI-GGUF.git" "ComfyUI-GGUF"


# Function to download a model using huggingface-cli
download_model() {
    local url="$1"
    local full_path="$2"
    local hf_token="${HUGGINGFACE_TOKEN:-}"
    local start_ts=$(date +%s)

    local destination_dir=$(dirname "$full_path")
    local destination_file=$(basename "$full_path")

    mkdir -p "$destination_dir"

    # Corruption check
    if [ -f "$full_path" ]; then
        local size_bytes=$(stat -f%z "$full_path" 2>/dev/null || stat -c%s "$full_path" 2>/dev/null || echo 0)
        if [ "$size_bytes" -lt 10485760 ]; then
            echo "🗑️  Deleting corrupted file: $full_path"
            rm -f "$full_path"
        else
            echo "✅ $destination_file already exists, skipping."
            log_timing "direct_download" "$destination_file" "skipped_existing" "$start_ts" "$(date +%s)" "$size_bytes" "$url"
            return 0
        fi
    fi

    # Cleanup aria2 control files
    rm -f "${full_path}.aria2"

    echo "📥 Downloading $destination_file..."
    local -a aria2_args=(
        -x 16
        -s 16
        -k 1M
        --continue=true
        -d "$destination_dir"
        -o "$destination_file"
    )
    if [ -n "$hf_token" ]; then
        aria2_args+=(--header="Authorization: Bearer $hf_token")
    else
        echo "⚠️  HUGGINGFACE_TOKEN not set; downloading without Authorization header."
    fi
    aria2c "${aria2_args[@]}" "$url"
    local rc=$?
    local size_bytes=$(stat -f%z "$full_path" 2>/dev/null || stat -c%s "$full_path" 2>/dev/null || echo 0)
    local end_ts=$(date +%s)
    if [ $rc -eq 0 ]; then
        log_timing "direct_download" "$destination_file" "success" "$start_ts" "$end_ts" "$size_bytes" "$url"
    else
        log_timing "direct_download" "$destination_file" "failed" "$start_ts" "$end_ts" "$size_bytes" "$url"
    fi

    echo "Download started in background for $destination_file"
    return $rc
}

download_model_bg() {
    local url="$1"
    local full_path="$2"
    download_model "$url" "$full_path" &
    PRIMARY_MODEL_DOWNLOAD_PIDS+=($!)
    PRIMARY_MODEL_DOWNLOAD_LABELS+=("$full_path")
}

download_model_id_bg() {
    local target_dir="$1"
    local model_id="$2"
    (
        local start_ts=$(date +%s)
        cd "$target_dir" || exit 1
        download_with_aria.py -m "$model_id"
        local rc=$?
        local end_ts=$(date +%s)
        if [ $rc -eq 0 ]; then
            log_timing "model_id_download" "$model_id" "success" "$start_ts" "$end_ts" "0" "$target_dir"
        else
            log_timing "model_id_download" "$model_id" "failed" "$start_ts" "$end_ts" "0" "$target_dir"
        fi
        exit $rc
    ) &
    MODEL_ID_DOWNLOAD_PIDS+=($!)
    MODEL_ID_DOWNLOAD_LABELS+=("$model_id")
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

echo "📦 Starting model downloads..."

PRIMARY_MODEL_DOWNLOAD_PIDS=()
PRIMARY_MODEL_DOWNLOAD_LABELS=()
MODEL_ID_DOWNLOAD_PIDS=()
MODEL_ID_DOWNLOAD_LABELS=()

download_model_bg "https://huggingface.co/Comfy-Org/z_image/resolve/main/split_files/diffusion_models/z_image_bf16.safetensors" "$DIFFUSION_MODELS_DIR/z_image_bf16.safetensors"

download_model_bg "https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/diffusion_models/z_image_turbo_bf16.safetensors" "$DIFFUSION_MODELS_DIR/z_image_turbo.safetensors"

download_model_bg "https://huggingface.co/jeremyhola/LORAs/resolve/main/aiorbust/nsfw/z_image_turbo.safetensors" "$DIFFUSION_MODELS_DIR/z-image-turbo-nsfw.safetensors"

download_model_bg "https://huggingface.co/dci05049/z-image-lora/resolve/main/instagram_zimageturbo.safetensors" "$LORAS_DIR/instagram_zimageturbo.safetensors"

download_model_bg "https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/vae/ae.safetensors" "$VAE_DIR/ae.safetensors"

download_model_bg "https://huggingface.co/dci05049/z-image-lora/resolve/main/z_image_vae.safetensors" "$VAE_DIR/z_image_vae.safetensors"

download_model_bg "https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/text_encoders/qwen_3_4b.safetensors" "$TEXT_ENCODERS_DIR/qwen_3_4b.safetensors"

download_model_bg "https://huggingface.co/BennyDaBall/Qwen3-4b-Z-Image-Turbo-AbliteratedV1/resolve/main/Z-Image-AbliteratedV1.f16.gguf" "$TEXT_ENCODERS_DIR/Z-Image-AbliteratedV1.f16.gguf"

download_model_bg "https://huggingface.co/jeremyhola/LORAs/resolve/main/aiorbust/nsfw/Z-Image-AbliteratedV1.f16.safetensors" "$TEXT_ENCODERS_DIR/Z-Image-AbliteratedV1.f16.safetensors"

download_model_bg "https://huggingface.co/BennyDaBall/Qwen3-4b-Z-Image-Engineer-V4/resolve/main/Qwen3-4b-Z-Image-Engineer-V4-F16.gguf" "$TEXT_ENCODERS_DIR/Qwen3-4b-Z-Image-Engineer-V4-F16.gguf"

download_model_bg "https://huggingface.co/dci05049/z-image-lora/resolve/main/Sally_Lokr.safetensors" "$LORAS_DIR/Sally_Lokr.safetensors"

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

wait_for_all_model_downloads() {
    local failed_downloads=0
    local -a failed_items=()
    local i
    echo "Waiting for primary model downloads to complete..."
    for i in "${!PRIMARY_MODEL_DOWNLOAD_PIDS[@]}"; do
        local pid="${PRIMARY_MODEL_DOWNLOAD_PIDS[$i]}"
        local label="${PRIMARY_MODEL_DOWNLOAD_LABELS[$i]}"
        if ! wait "$pid"; then
            failed_downloads=$((failed_downloads + 1))
            failed_items+=("$label")
        fi
    done

    echo "Waiting for model-id downloads to complete..."
    for i in "${!MODEL_ID_DOWNLOAD_PIDS[@]}"; do
        local pid="${MODEL_ID_DOWNLOAD_PIDS[$i]}"
        local label="${MODEL_ID_DOWNLOAD_LABELS[$i]}"
        if ! wait "$pid"; then
            failed_downloads=$((failed_downloads + 1))
            failed_items+=("$label")
        fi
    done

    echo "Waiting for all aria2 downloads to complete..."
    while pgrep -x "aria2c" > /dev/null; do
        echo "🔽 Model downloads still in progress..."
        sleep 5
    done
    if [ "$failed_downloads" -gt 0 ]; then
        echo "❌ $failed_downloads model download task(s) failed. See $TIMING_LOG for details."
        echo "Failed model download items:"
        local failed_item
        for failed_item in "${failed_items[@]}"; do
            echo " - $failed_item"
        done
        log_timing "installation" "model_downloads" "failed" "$INSTALL_START_TS" "$(date +%s)" "0" "$TIMING_LOG"
        return 1
    fi
    echo "All model downloads completed"
    return 0
}

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

# Workspace as main working directory
echo "cd $NETWORK_VOLUME" >> ~/.bashrc



echo "Renaming loras downloaded as zip files to safetensors files"
finalize_model_downloads() {
    local install_finish_start_ts=$(date +%s)
    if ! wait_for_all_model_downloads; then
        return 1
    fi
    cd "$LORAS_DIR"
    for file in *.zip; do
        [ -f "$file" ] || continue
        mv "$file" "${file%.zip}.safetensors"
    done
    local install_end_ts=$(date +%s)
    log_timing "installation" "all_downloads" "completed" "$INSTALL_START_TS" "$install_end_ts" "0" "$TIMING_LOG"
    log_timing "installation" "finalize_step" "completed" "$install_finish_start_ts" "$install_end_ts" "0" "$TIMING_LOG"
    echo "Timing log available at: $TIMING_LOG"
}

if ! finalize_model_downloads; then
    echo "Model installation failed; refusing to start ComfyUI."
    exit 1
fi

ensure_required_text_encoders() {
    local missing=0
    local encoder_path=""
    local -a required_text_encoders=(
        "$TEXT_ENCODERS_DIR/qwen_3_4b.safetensors"
        "$TEXT_ENCODERS_DIR/Z-Image-AbliteratedV1.f16.gguf"
        "$TEXT_ENCODERS_DIR/Z-Image-AbliteratedV1.f16.safetensors"
        "$TEXT_ENCODERS_DIR/Qwen3-4b-Z-Image-Engineer-V4-F16.gguf"
    )

    for encoder_path in "${required_text_encoders[@]}"; do
        if [ ! -f "$encoder_path" ]; then
            echo "❌ Missing text encoder: $encoder_path"
            missing=$((missing + 1))
            continue
        fi

        local size_bytes
        size_bytes=$(stat -f%z "$encoder_path" 2>/dev/null || stat -c%s "$encoder_path" 2>/dev/null || echo 0)
        if [ "$size_bytes" -lt 10485760 ]; then
            echo "❌ Text encoder appears incomplete (<10MB): $encoder_path"
            missing=$((missing + 1))
        fi
    done

    if [ "$missing" -gt 0 ]; then
        log_timing "preflight" "text_encoders" "failed_missing_or_incomplete" "$INSTALL_START_TS" "$(date +%s)" "0" "$TEXT_ENCODERS_DIR"
        return 1
    fi

    log_timing "preflight" "text_encoders" "success" "$INSTALL_START_TS" "$(date +%s)" "0" "$TEXT_ENCODERS_DIR"
    return 0
}

if ! ensure_required_text_encoders; then
    echo "Text encoder preflight failed; refusing to start ComfyUI."
    exit 1
fi

ensure_required_vae_models() {
    local missing=0
    local vae_path=""
    local -a required_vae_models=(
        "$VAE_DIR/ae.safetensors"
        "$VAE_DIR/z_image_vae.safetensors"
    )

    for vae_path in "${required_vae_models[@]}"; do
        if [ ! -f "$vae_path" ]; then
            echo "❌ Missing VAE model: $vae_path"
            missing=$((missing + 1))
            continue
        fi

        local size_bytes
        size_bytes=$(stat -f%z "$vae_path" 2>/dev/null || stat -c%s "$vae_path" 2>/dev/null || echo 0)
        if [ "$size_bytes" -lt 10485760 ]; then
            echo "❌ VAE model appears incomplete (<10MB): $vae_path"
            missing=$((missing + 1))
        fi
    done

    if [ "$missing" -gt 0 ]; then
        log_timing "preflight" "vae_models" "failed_missing_or_incomplete" "$INSTALL_START_TS" "$(date +%s)" "0" "$VAE_DIR"
        return 1
    fi

    log_timing "preflight" "vae_models" "success" "$INSTALL_START_TS" "$(date +%s)" "0" "$VAE_DIR"
    return 0
}

if ! ensure_required_vae_models; then
    echo "VAE preflight failed; refusing to start ComfyUI."
    exit 1
fi

if [ "$USE_SAGE_ATTENTION" = "1" ]; then
    # Wait for SageAttention build to complete
    echo "Waiting for SageAttention build to complete..."
    sage_status="failed"
    while ! [ -f /tmp/sage_build_done ]; do
        if ps -p $SAGE_PID > /dev/null 2>&1; then
            echo "⚙️  SageAttention build in progress, this may take up to 5 minutes."
            sleep 5
        else
            # Process finished but no completion marker - check if it failed
            if ! [ -f /tmp/sage_build_done ]; then
                echo "⚠️  SageAttention build process ended unexpectedly. Check logs at /tmp/sage_build.log"
                echo "Continuing with ComfyUI startup..."
                sage_status="failed"
                break
            fi
        fi
    done

    if [ -f /tmp/sage_build_done ]; then
        echo "✅ SageAttention build completed successfully!"
        sage_status="success"
    fi
    sage_end_ts=$(date +%s)
    log_timing "build" "sageattention" "$sage_status" "$SAGE_BUILD_START_TS" "$sage_end_ts" "0" "/tmp/sage_build.log"
fi

# Start ComfyUI

echo "Starting ComfyUI"
COMFY_ARGS=(--listen)
if [ "$USE_SAGE_ATTENTION" = "1" ]; then
    COMFY_ARGS+=(--use-sage-attention)
fi

if ! cuda_preflight_ok; then
    echo "❌ FATAL: CUDA preflight failed. ComfyUI will not start."
    echo "❌ FATAL: Check pod GPU attachment/runtime configuration and CUDA environment."
    echo "❌ FATAL: Startup aborted before launching main.py."
    log_timing "startup" "cuda_preflight" "failed_abort" "$INSTALL_START_TS" "$(date +%s)" "0" "torch.cuda"
    exit 1
fi

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
