#!/usr/bin/env bash
set -euo pipefail

RUNPOD_API_BASE="${RUNPOD_API_BASE:-https://rest.runpod.io/v1}"
RUNPOD_TEMPLATE_ID="${RUNPOD_TEMPLATE_ID:-}"
RUNPOD_API_KEY="${RUNPOD_API_KEY:-}"
RUNPOD_GPU_TYPE_ID="${RUNPOD_GPU_TYPE_ID:-NVIDIA L40S}"
RUNPOD_GPU_COUNT="${RUNPOD_GPU_COUNT:-1}"
RUNPOD_CLOUD_TYPE="${RUNPOD_CLOUD_TYPE:-SECURE}"
RUNPOD_IMAGE_NAME="${RUNPOD_IMAGE_NAME:-}"
RUNPOD_HEALTH_TIMEOUT_SECONDS="${RUNPOD_HEALTH_TIMEOUT_SECONDS:-1200}"
RUNPOD_STATUS_POLL_SECONDS="${RUNPOD_STATUS_POLL_SECONDS:-10}"
RUNPOD_KEEP_POD="${RUNPOD_KEEP_POD:-0}"
RUNPOD_POD_NAME_PREFIX="${RUNPOD_POD_NAME_PREFIX:-smoke}"

if [[ -z "$RUNPOD_API_KEY" ]]; then
    echo "RUNPOD_API_KEY is required." >&2
    exit 1
fi
if [[ -z "$RUNPOD_TEMPLATE_ID" ]]; then
    echo "RUNPOD_TEMPLATE_ID is required." >&2
    exit 1
fi

if ! [[ "$RUNPOD_GPU_COUNT" =~ ^[0-9]+$ ]] || [[ "$RUNPOD_GPU_COUNT" -lt 1 ]]; then
    echo "RUNPOD_GPU_COUNT must be a positive integer." >&2
    exit 1
fi

is_truthy() {
    local value="${1,,}"
    [[ "$value" == "1" || "$value" == "true" || "$value" == "yes" || "$value" == "y" ]]
}

pod_id=""
created_pod=0

api_request() {
    local method="$1"
    local path="$2"
    local body="${3:-}"
    if [[ -n "$body" ]]; then
        curl -fsS -X "$method" \
            -H "Authorization: Bearer $RUNPOD_API_KEY" \
            -H "Content-Type: application/json" \
            "$RUNPOD_API_BASE$path" \
            -d "$body"
    else
        curl -fsS -X "$method" \
            -H "Authorization: Bearer $RUNPOD_API_KEY" \
            "$RUNPOD_API_BASE$path"
    fi
}

cleanup() {
    if [[ "$created_pod" -ne 1 ]] || [[ -z "$pod_id" ]]; then
        return 0
    fi
    if is_truthy "$RUNPOD_KEEP_POD"; then
        echo "Keeping pod $pod_id (RUNPOD_KEEP_POD=1)."
        return 0
    fi
    echo "Cleaning up pod $pod_id..."
    if ! api_request "DELETE" "/pods/$pod_id" >/dev/null 2>&1; then
        echo "DELETE failed, attempting stop..."
        api_request "POST" "/pods/$pod_id/stop" "{}" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

pod_name="${RUNPOD_POD_NAME_PREFIX}-$(date +%Y%m%d-%H%M%S)"

create_payload="$(
python3 - <<PY
import json
import os

payload = {
    "name": os.environ["pod_name"],
    "templateId": os.environ["RUNPOD_TEMPLATE_ID"],
    "computeType": "GPU",
    "cloudType": os.environ["RUNPOD_CLOUD_TYPE"],
    "gpuTypeIds": [os.environ["RUNPOD_GPU_TYPE_ID"]],
    "gpuCount": int(os.environ["RUNPOD_GPU_COUNT"]),
    "ports": ["8188/http", "8888/http"],
    "supportPublicIp": True,
}
image_name = os.environ.get("RUNPOD_IMAGE_NAME", "").strip()
if image_name:
    payload["image"] = image_name
print(json.dumps(payload))
PY
)"

echo "Creating Runpod pod from template $RUNPOD_TEMPLATE_ID..."
create_response="$(api_request "POST" "/pods" "$create_payload")"
pod_id="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$create_response")"
created_pod=1

echo "Created pod: $pod_id"
echo "Waiting for desiredStatus=RUNNING..."

max_polls=$((RUNPOD_HEALTH_TIMEOUT_SECONDS / RUNPOD_STATUS_POLL_SECONDS))
if [[ "$max_polls" -lt 1 ]]; then
    max_polls=1
fi

pod_json=""
for ((i = 1; i <= max_polls; i++)); do
    pod_json="$(api_request "GET" "/pods/$pod_id")"
    desired_status="$(python3 -c 'import json,sys; print((json.load(sys.stdin).get("desiredStatus") or "").strip())' <<<"$pod_json")"
    echo "Poll $i/$max_polls: desiredStatus=$desired_status"
    if [[ "$desired_status" == "RUNNING" ]]; then
        break
    fi
    sleep "$RUNPOD_STATUS_POLL_SECONDS"
done

if [[ "$desired_status" != "RUNNING" ]]; then
    echo "Pod did not reach RUNNING within timeout." >&2
    exit 1
fi

proxy_url="https://${pod_id}-8188.proxy.runpod.net"
public_ip="$(python3 -c 'import json,sys; print((json.load(sys.stdin).get("publicIp") or "").strip())' <<<"$pod_json")"
mapped_8188="$(
python3 - <<'PY' <<<"$pod_json"
import json
import sys
d = json.load(sys.stdin)
mapping = d.get("portMappings") or {}
val = mapping.get("8188")
if val is None:
    val = mapping.get(8188)
print("" if val is None else str(val))
PY
)"

direct_url=""
if [[ -n "$public_ip" ]] && [[ -n "$mapped_8188" ]]; then
    direct_url="http://${public_ip}:${mapped_8188}"
fi

echo "Health-checking ComfyUI endpoint..."
health_ok=0
for ((i = 1; i <= max_polls; i++)); do
    if curl -fsS --max-time 10 "$proxy_url" >/dev/null 2>&1; then
        echo "ComfyUI healthy via proxy: $proxy_url"
        health_ok=1
        break
    fi
    if [[ -n "$direct_url" ]] && curl -fsS --max-time 10 "$direct_url" >/dev/null 2>&1; then
        echo "ComfyUI healthy via direct URL: $direct_url"
        health_ok=1
        break
    fi
    echo "Health poll $i/$max_polls: still waiting..."
    sleep "$RUNPOD_STATUS_POLL_SECONDS"
done

if [[ "$health_ok" -ne 1 ]]; then
    echo "ComfyUI health check failed." >&2
    echo "Tried proxy URL: $proxy_url" >&2
    if [[ -n "$direct_url" ]]; then
        echo "Tried direct URL: $direct_url" >&2
    fi
    exit 1
fi

echo "Runpod smoke test passed."
