#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, List, Sequence, Set, Tuple

CORE_NODE_TYPES: Set[str] = {
    "CheckpointLoaderSimple",
    "CLIPTextEncode",
    "KSampler",
    "VAEDecode",
    "SaveImage",
    "LoadImage",
    "EmptyLatentImage",
    "VAEEncode",
    "VAELoader",
    "LoraLoader",
    "ControlNetLoader",
    "CLIPLoader",
    "UNETLoader",
    "DualCLIPLoader",
    "KSamplerAdvanced",
    "LoadImageMask",
    "PreviewImage",
    "ConditioningCombine",
    "ConditioningSetArea",
    "ConditioningSetMask",
    "LatentUpscale",
    "ImageScale",
    "ImageUpscaleWithModel",
    "UpscaleModelLoader",
}

MODEL_EXTENSIONS = {
    ".safetensors",
    ".ckpt",
    ".pt",
    ".pth",
    ".bin",
    ".onnx",
    ".gguf",
    ".engine",
    ".json",
}


@dataclass
class FileCandidate:
    filename: str
    context_key: str


def load_json(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        raise SystemExit(f"Failed to parse JSON at {path}: {exc}")

    if not isinstance(data, dict):
        raise SystemExit("Workflow root must be a JSON object.")
    return data


def iter_strings(value: object, key_path: str = "") -> Iterable[Tuple[str, str]]:
    if isinstance(value, str):
        yield key_path, value
        return
    if isinstance(value, list):
        for idx, item in enumerate(value):
            child_key = f"{key_path}[{idx}]" if key_path else f"[{idx}]"
            yield from iter_strings(item, child_key)
        return
    if isinstance(value, dict):
        for key, item in value.items():
            child_key = f"{key_path}.{key}" if key_path else str(key)
            yield from iter_strings(item, child_key)


def looks_like_file_name(text: str) -> bool:
    lowered = text.lower().strip()
    if "/" in lowered:
        return False
    if " " in lowered:
        return False
    return Path(lowered).suffix in MODEL_EXTENSIONS


def parse_workflow_nodes(workflow: dict) -> Tuple[Set[str], List[FileCandidate]]:
    node_types: Set[str] = set()
    files: List[FileCandidate] = []

    if "nodes" in workflow and isinstance(workflow["nodes"], list):
        for node in workflow["nodes"]:
            if not isinstance(node, dict):
                continue
            node_type = node.get("type") or node.get("class_type")
            if isinstance(node_type, str) and node_type.strip():
                node_types.add(node_type.strip())

            for block_name in ("widgets_values", "inputs"):
                block = node.get(block_name)
                if block is None:
                    continue
                for path, value in iter_strings(block, block_name):
                    if looks_like_file_name(value):
                        files.append(FileCandidate(filename=value.strip(), context_key=path))

    for node_id, node in workflow.items():
        if not isinstance(node_id, str) or not node_id.isdigit() or not isinstance(node, dict):
            continue
        node_type = node.get("class_type")
        if isinstance(node_type, str) and node_type.strip():
            node_types.add(node_type.strip())

        inputs = node.get("inputs")
        if inputs is None:
            continue
        for path, value in iter_strings(inputs, f"{node_id}.inputs"):
            if looks_like_file_name(value):
                files.append(FileCandidate(filename=value.strip(), context_key=path))

    return node_types, dedupe_file_candidates(files)


def dedupe_file_candidates(files: Sequence[FileCandidate]) -> List[FileCandidate]:
    seen: Set[str] = set()
    deduped: List[FileCandidate] = []
    for item in files:
        key = item.filename.lower()
        if key in seen:
            continue
        seen.add(key)
        deduped.append(item)
    return deduped


def infer_target_dir(file_name: str, context_key: str) -> str:
    lowered_name = file_name.lower()
    lowered_context = context_key.lower()

    if "vae" in lowered_name or "vae" in lowered_context:
        return "models/vae"
    if "lora" in lowered_name or "lora" in lowered_context:
        return "models/loras"
    if "control" in lowered_name or "control" in lowered_context:
        return "models/controlnet"
    if "clip" in lowered_name or "text" in lowered_context or "encoder" in lowered_context:
        return "models/text_encoders"
    if "unet" in lowered_name or "diffusion" in lowered_context:
        return "models/diffusion_models"
    if "sam" in lowered_name:
        return "models/sams"
    if "upscale" in lowered_name:
        return "models/upscale_models"

    ext = Path(file_name).suffix.lower()
    if ext in {".safetensors", ".ckpt"}:
        return "models/checkpoints"
    if ext in {".pt", ".pth"}:
        return "models/ultralytics/bbox"
    return "models/custom"


def build_requirement_pack(workflow_path: Path) -> dict:
    workflow = load_json(workflow_path)
    node_types, file_candidates = parse_workflow_nodes(workflow)

    custom_nodes = []
    for node_type in sorted(node_types):
        if node_type in CORE_NODE_TYPES:
            continue
        custom_nodes.append(
            {
                "node_type": node_type,
                "search_query": f"{node_type} ComfyUI custom node github",
            }
        )

    files = []
    for candidate in file_candidates:
        target_dir = infer_target_dir(candidate.filename, candidate.context_key)
        files.append(
            {
                "filename": candidate.filename,
                "context_key": candidate.context_key,
                "suggested_target": f"{target_dir}/{candidate.filename}",
                "search_query": f"{candidate.filename} ComfyUI download",
            }
        )

    return {
        "custom_nodes": custom_nodes,
        "files": files,
        "playwright_required": True,
        "instructions": [
            "Use Playwright tools to execute each search_query and collect the best source URL.",
            "Validate each candidate by opening it in Playwright and checking it resolves to the expected repository/file.",
            "Set require_huggingface_token=true in the final manifest if any selected Hugging Face file is gated or requires auth.",
        ],
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Extract required custom-node and model-file candidates from a ComfyUI workflow. "
            "Use Playwright after extraction to find and validate final source links."
        )
    )
    parser.add_argument("--workflow", required=True, help="Path to ComfyUI workflow JSON file.")
    parser.add_argument(
        "--output",
        default="",
        help="Optional path to write extracted requirement pack JSON. Prints to stdout when omitted.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    workflow_path = Path(args.workflow)

    if not workflow_path.is_file():
        raise SystemExit(f"Workflow file not found: {workflow_path}")

    payload = build_requirement_pack(workflow_path=workflow_path)
    rendered = json.dumps(payload, indent=2, ensure_ascii=False)

    if args.output:
        output_path = Path(args.output)
        output_path.write_text(rendered + "\n", encoding="utf-8")
        print(str(output_path))
    else:
        print(rendered)


if __name__ == "__main__":
    main()
