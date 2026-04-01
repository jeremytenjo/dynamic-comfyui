FROM runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404

ENV PYTHONUNBUFFERED=1
WORKDIR /
ARG COMFYUI_VERSION=v0.18.2
ARG COMFYUI_UPDATE_TOKEN=stable
ARG COMFYUI_UPGRADE=false

RUN apt-get update --yes && \
    DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends \
    git \
    curl \
    wget \
    zip \
    libgoogle-perftools4 && \
    rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir --upgrade pip
RUN python3 -m pip install --no-cache-dir comfy-cli

RUN set -eux; \
    echo "ComfyUI update token: ${COMFYUI_UPDATE_TOKEN}"; \
    echo "ComfyUI upgrade mode: ${COMFYUI_UPGRADE}"; \
    COMFYUI_INSTALL_VERSION="${COMFYUI_VERSION}"; \
    COMFYUI_INSTALL_VERSION="$(printf '%s' "${COMFYUI_INSTALL_VERSION}" | tr -d '[:space:]')"; \
    if [ -z "${COMFYUI_INSTALL_VERSION}" ]; then \
        COMFYUI_INSTALL_VERSION="v0.18.2"; \
    elif printf '%s' "${COMFYUI_INSTALL_VERSION}" | grep -Eq '^v?[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z]+)*$'; then \
        true; \
    elif [ "${COMFYUI_INSTALL_VERSION}" = "latest" ] || [ "${COMFYUI_INSTALL_VERSION}" = "stable" ] || [ "${COMFYUI_INSTALL_VERSION}" = "nightly" ]; then \
        echo "⚠️ COMFYUI_VERSION='${COMFYUI_INSTALL_VERSION}' is legacy; using pinned default v0.18.2."; \
        COMFYUI_INSTALL_VERSION="v0.18.2"; \
    else \
        echo "❌ COMFYUI_VERSION must be semver (example: 0.18.2 or v0.18.2). Got: '${COMFYUI_INSTALL_VERSION}'."; \
        exit 1; \
    fi; \
    if [ -d "/ComfyUI/.git" ] && [ "${COMFYUI_UPGRADE}" != "true" ]; then \
        echo "ComfyUI already present in base image. Skipping install because COMFYUI_UPGRADE=false."; \
    else \
        rm -rf /ComfyUI; \
        git clone https://github.com/comfyanonymous/ComfyUI.git /ComfyUI; \
        cd /ComfyUI; \
        git fetch --tags --force; \
        if git rev-parse -q --verify "v${COMFYUI_INSTALL_VERSION#v}^{commit}" >/dev/null 2>&1; then \
            git checkout -q "v${COMFYUI_INSTALL_VERSION#v}"; \
        elif git rev-parse -q --verify "${COMFYUI_INSTALL_VERSION#v}^{commit}" >/dev/null 2>&1; then \
            git checkout -q "${COMFYUI_INSTALL_VERSION#v}"; \
        else \
            echo "❌ Requested ComfyUI version ref not found: ${COMFYUI_INSTALL_VERSION}"; \
            exit 1; \
        fi; \
        python3 -m pip install --no-cache-dir -r /ComfyUI/requirements.txt; \
    fi

COPY start.sh /start.sh
COPY start-new-project.sh /start-new-project.sh
COPY install.sh /install.sh
COPY update-nodes-and-models.sh /update-nodes-and-models.sh
COPY restart-comfyui.sh /restart-comfyui.sh
COPY projects /projects
COPY handlers /handlers

RUN chmod +x /start.sh /start-new-project.sh /install.sh /update-nodes-and-models.sh /restart-comfyui.sh

EXPOSE 8188 8888

CMD ["/install.sh"]
