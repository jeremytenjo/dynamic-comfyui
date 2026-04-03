# shellcheck shell=bash


serve_setup_instructions_page() {
    local setup_dir
    setup_dir="$(setup_page_dir_path)"
    local setup_html="$setup_dir/index.html"
    local setup_pid_file="/tmp/dynamic-comfyui-setup-page.pid"
    local comfy_health_url="http://127.0.0.1:8188/system_stats"

    # If ComfyUI is already reachable, don't start a placeholder page.
    if is_http_reachable "$comfy_health_url" 2 5; then
        return 0
    fi

    mkdir -p "$setup_dir"
    setup_progress_mark_idle
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
    .progress {
      margin-top: 18px;
      padding-top: 16px;
      border-top: 1px solid #334155;
    }
    .progress h2 {
      margin: 0 0 8px;
      font-size: 20px;
    }
    .status {
      margin: 0 0 12px;
      font-size: 14px;
      color: #cbd5e1;
    }
    .summary {
      margin: 0 0 12px;
      font-size: 13px;
      color: #93c5fd;
    }
    .message {
      margin: 0 0 12px;
      font-size: 13px;
      color: #cbd5e1;
      word-break: break-word;
    }
    .message-error {
      color: #fca5a5;
    }
    .checklist {
      margin: 0;
      padding: 0;
      list-style: none;
      display: grid;
      gap: 8px;
      max-height: 260px;
      overflow: auto;
    }
    .checklist li {
      display: flex;
      align-items: center;
      gap: 10px;
      font-size: 14px;
      color: #cbd5e1;
      background: #0b1328;
      border: 1px solid #1f2a44;
      border-radius: 8px;
      padding: 8px 10px;
    }
    .groups {
      display: grid;
      gap: 14px;
    }
    .group h3 {
      margin: 0 0 8px;
      font-size: 14px;
      color: #93c5fd;
      letter-spacing: 0.02em;
    }
    .checklist input[type="checkbox"] {
      margin: 0;
      accent-color: #22c55e;
    }
    .target {
      word-break: break-word;
      flex: 1;
    }
    .item-status {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      width: 16px;
      height: 16px;
      flex: 0 0 16px;
    }
    .spinner {
      width: 14px;
      height: 14px;
      border: 2px solid #334155;
      border-top-color: #93c5fd;
      border-radius: 50%;
      animation: spin 0.8s linear infinite;
    }
    .check-emoji {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      width: 16px;
      height: 16px;
      flex: 0 0 16px;
      font-size: 15px;
      line-height: 1;
    }
    @keyframes spin {
      from { transform: rotate(0deg); }
      to { transform: rotate(360deg); }
    }
    a.inline-link {
      color: #93c5fd;
      text-decoration: underline;
    }
    a.inline-link:hover {
      color: #bfdbfe;
    }
  </style>
</head>
<body>
  <main class="card">
    <h1>ComfyUI is not installed yet</h1>
    <p>Finish one-time setup from Jupyter, then this port will switch to ComfyUI automatically.</p>
    <ol>
      <li>Open <a id="jupyter-link" class="inline-link" href="#" target="_blank" rel="noopener noreferrer">Jupyter Lab (port 8888)</a>.</li>
      <li>Open a terminal in Jupyter.</li>
      <li>Run <code>bash start.sh</code></li>
    </ol>
    <p>The installer downloads files and custom nodes, then starts ComfyUI on port 8188.</p>
    <p class="hint">You can keep this tab open and refresh after installation completes.</p>
    <section class="progress">
      <h2>Download checklist</h2>
      <p id="progress-status" class="status">Status: Pending</p>
      <p id="progress-summary" class="summary">0/0 complete • 0 left</p>
      <p id="progress-message" class="message"></p>
      <div id="progress-groups" class="groups"></div>
    </section>
  </main>
  <script>
    function buildJupyterUrl() {
      const current = window.location;
      const protocol = current.protocol || "https:";
      const host = current.hostname || "";
      const swapped = host.replace(/-8188(?=\\.)/, "-8888");
      if (swapped !== host) {
        return `${protocol}//${swapped}/lab`;
      }
      const fallbackHost = host;
      return `${protocol}//${fallbackHost}:8888/lab`;
    }

    function setJupyterLink() {
      const el = document.getElementById("jupyter-link");
      if (!el) return;
      el.href = buildJupyterUrl();
    }

    function humanStatus(raw) {
      const map = {
        idle: "Pending",
        running: "Running",
        done: "Done",
        failed: "Failed",
      };
      return map[raw] || "Pending";
    }

    function renderProgress(payload) {
      const statusEl = document.getElementById("progress-status");
      const summaryEl = document.getElementById("progress-summary");
      const messageEl = document.getElementById("progress-message");
      const groupsEl = document.getElementById("progress-groups");
      if (!statusEl || !summaryEl || !messageEl || !groupsEl) return;

      const statusText = humanStatus(payload?.status);
      statusEl.textContent = `Status: ${statusText}`;
      messageEl.textContent = payload?.message || "";
      messageEl.classList.toggle("message-error", payload?.status === "failed");
      const isRunning = payload?.status === "running";

      const defaultGroup = payload?.groups?.default || { label: "Default resources", items: [] };
      const projectGroup = payload?.groups?.project || { label: "Project manifest", items: [] };
      const allCount = (defaultGroup.items?.length || 0) + (projectGroup.items?.length || 0);
      const doneCount = (defaultGroup.items || []).filter((item) => item.checked).length +
        (projectGroup.items || []).filter((item) => item.checked).length;
      const leftCount = Math.max(allCount - doneCount, 0);
      summaryEl.textContent = `${doneCount}/${allCount} complete • ${leftCount} left`;
      if (allCount === 0) {
        groupsEl.innerHTML = "<ul class=\"checklist\"><li>No checklist items yet.</li></ul>";
        return;
      }

      groupsEl.innerHTML = "";

      function groupCounts(group) {
        const total = Array.isArray(group.items) ? group.items.length : 0;
        const done = (group.items || []).filter((item) => item.checked).length;
        const left = Math.max(total - done, 0);
        return { total, done, left };
      }

      function renderGroup(group) {
        const wrapper = document.createElement("div");
        wrapper.className = "group";
        const heading = document.createElement("h3");
        const counts = groupCounts(group);
        heading.textContent = `${group.label} (${counts.done}/${counts.total}, ${counts.left} left)`;
        wrapper.appendChild(heading);
        const listEl = document.createElement("ul");
        listEl.className = "checklist";
        if (!Array.isArray(group.items) || group.items.length === 0) {
          listEl.innerHTML = "<li>(none)</li>";
          wrapper.appendChild(listEl);
          groupsEl.appendChild(wrapper);
          return;
        }

        for (const item of group.items) {
          const li = document.createElement("li");
          const target = document.createElement("span");
          target.className = "target";
          target.textContent = item.target || "(unknown target)";
          if (isRunning && !item.checked) {
            const itemStatus = document.createElement("span");
            itemStatus.className = "item-status";
            const spinner = document.createElement("span");
            spinner.className = "spinner";
            spinner.setAttribute("aria-label", "Loading");
            spinner.title = "Loading";
            itemStatus.appendChild(spinner);
            li.appendChild(itemStatus);
          } else if (item.checked) {
            const checkEmoji = document.createElement("span");
            checkEmoji.className = "check-emoji";
            checkEmoji.setAttribute("aria-label", "Completed");
            checkEmoji.title = "Completed";
            checkEmoji.textContent = "✅";
            li.appendChild(checkEmoji);
          } else {
            const checkbox = document.createElement("input");
            checkbox.type = "checkbox";
            checkbox.disabled = true;
            checkbox.checked = Boolean(item.checked);
            li.appendChild(checkbox);
          }
          li.appendChild(target);
          listEl.appendChild(li);
        }
        wrapper.appendChild(listEl);
        groupsEl.appendChild(wrapper);
      }

      renderGroup(defaultGroup);
      renderGroup(projectGroup);
    }

    async function pollProgress() {
      try {
        const res = await fetch(`/progress.json?t=${Date.now()}`, { cache: "no-store" });
        if (!res.ok) return;
        const payload = await res.json();
        renderProgress(payload);
      } catch (_err) {
        // keep previous UI state on transient errors
      }
    }

    setJupyterLink();
    pollProgress();
    setInterval(pollProgress, 2000);
  </script>
</body>
</html>
EOF

    # If something else already binds 8188, do nothing and keep startup resilient.
    if is_http_reachable "http://127.0.0.1:8188" 2 5; then
        return 0
    fi

    nohup python3 -m http.server 8188 --bind 0.0.0.0 --directory "$setup_dir" >/tmp/dynamic-comfyui-setup-page.log 2>&1 &
    echo $! > "$setup_pid_file"
    echo "Serving setup instructions on port 8188 until ComfyUI starts."
}
