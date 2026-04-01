# shellcheck shell=bash


serve_setup_instructions_page() {
    local setup_dir="/tmp/avatary-setup-page"
    local setup_html="$setup_dir/index.html"
    local setup_pid_file="/tmp/avatary-setup-page.pid"
    local comfy_health_url="http://127.0.0.1:8188/system_stats"

    # If ComfyUI is already reachable, don't start a placeholder page.
    if curl --silent --fail "$comfy_health_url" --output /dev/null; then
        return 0
    fi

    mkdir -p "$setup_dir"
    cat > "$setup_html" <<'EOF'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>ComfyUI Setup Required</title>
  <style>
    :root { color-scheme: light; }
    body {
      margin: 0;
      font-family: ui-sans-serif, -apple-system, Segoe UI, Roboto, Helvetica, Arial, sans-serif;
      background: #0f172a;
      color: #e2e8f0;
      min-height: 100vh;
      display: grid;
      place-items: center;
      padding: 24px;
      box-sizing: border-box;
    }
    .card {
      width: min(760px, 100%);
      background: #111827;
      border: 1px solid #334155;
      border-radius: 14px;
      padding: 24px;
      box-shadow: 0 20px 40px rgba(0, 0, 0, 0.35);
    }
    h1 { margin: 0 0 10px; font-size: 28px; }
    p { margin: 0 0 14px; line-height: 1.5; }
    ol { margin: 10px 0 14px 20px; line-height: 1.6; }
    code {
      display: inline-block;
      background: #020617;
      border: 1px solid #334155;
      border-radius: 8px;
      padding: 8px 10px;
      font-size: 14px;
      color: #bfdbfe;
    }
    .hint {
      margin-top: 12px;
      color: #93c5fd;
      font-size: 14px;
    }
  </style>
</head>
<body>
  <main class="card">
    <h1>ComfyUI is not installed yet</h1>
    <p>Finish one-time setup from Jupyter, then this port will switch to ComfyUI automatically.</p>
    <ol>
      <li>Open Jupyter Lab (port 8888).</li>
      <li>Open a terminal in Jupyter.</li>
      <li>Run <code>bash start.sh</code></li>
    </ol>
    <p>The installer downloads models and custom nodes, then starts ComfyUI on port 8188.</p>
    <p class="hint">You can keep this tab open and refresh after installation completes.</p>
  </main>
</body>
</html>
EOF

    # If something else already binds 8188, do nothing and keep startup resilient.
    if curl --silent --fail "http://127.0.0.1:8188" --output /dev/null; then
        return 0
    fi

    nohup python3 -m http.server 8188 --bind 0.0.0.0 --directory "$setup_dir" >/tmp/avatary-setup-page.log 2>&1 &
    echo $! > "$setup_pid_file"
    echo "Serving setup instructions on port 8188 until ComfyUI starts."
}
