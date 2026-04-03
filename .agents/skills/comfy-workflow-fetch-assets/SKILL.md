---
name: comfy-workflow-fetch-assets
description: Extract required ComfyUI custom-node and model-file requirements from a workflow JSON, then use Playwright browsing to find and validate the correct source links before generating a project manifest. Use when a user asks to build or refresh `custom_nodes`/`files` from a workflow and wants web-verified links with correct `require_huggingface_token` handling.
---

# Comfy Workflow Fetch Assets

Convert a ComfyUI workflow into a validated project manifest.

## Required Tooling

Use Playwright MCP tools for link discovery and validation. Do not rely on blind HTTP scraping for final link selection.

## Workflow

1. Extract requirements from workflow.

```bash
python3 scripts/discover_and_validate_assets.py --workflow /abs/path/workflow.json --output /tmp/requirements.json
```

2. Use Playwright to discover correct links.
- For each `custom_nodes[].search_query`, search in browser and pick the canonical repo URL (prefer GitHub repo root, then Hugging Face Space/repo if node is hosted there).
- For each `files[].search_query`, search in browser and pick the direct download/source URL that matches the exact filename.

3. Validate links in Playwright.
- Open each candidate URL in browser.
- Confirm the page matches the expected asset/repository name.
- Reject links that redirect to unrelated pages, search homepages, or generic landing pages.

4. Build final manifest.
- Create JSON with:
  - `require_huggingface_token` boolean
  - `custom_nodes`: `{ "repo_dir", "repo" }`
  - `files`: `{ "url", "target" }`

5. Set `require_huggingface_token`.
- Set `true` if any selected Hugging Face file is gated/private or authentication is required.
- Otherwise set `false`.

## Selection Rules

- Prefer official upstream sources: GitHub repository, Hugging Face model repo, Civitai model download API.
- Prefer stable links (`/resolve/main/...`, release assets, raw file URLs) over transient query URLs.
- Keep only one URL per required file.
- Keep `target` paths consistent with this repo conventions (for example `models/checkpoints`, `models/loras`, `models/vae`, `models/text_encoders`).

## Output Quality Checks

- Every required custom node has one repository URL.
- Every required file candidate has one validated URL and target path.
- Manifest JSON parses cleanly.
- `require_huggingface_token` is explicitly present and boolean.
