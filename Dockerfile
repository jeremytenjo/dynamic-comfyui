FROM runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404

ENV PYTHONUNBUFFERED=1
WORKDIR /
ARG COMFYUI_VERSION=v0.18.2
ARG COMFYUI_UPDATE_TOKEN=stable

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

RUN echo "ComfyUI update token: ${COMFYUI_UPDATE_TOKEN}" && \
    noninteractive_args="--skip-prompt" && \
    comfy --skip-prompt tracking disable >/dev/null 2>&1 || true && \
    export COMFYUI_INSTALL_VERSION="${COMFYUI_VERSION}" && \
    if [ -z "${COMFYUI_INSTALL_VERSION}" ]; then \
        COMFYUI_INSTALL_VERSION="v0.18.2"; \
        comfy ${noninteractive_args} --workspace=/ install --nvidia --skip-torch-or-directml --version "${COMFYUI_INSTALL_VERSION}"; \
    elif printf '%s' "${COMFYUI_INSTALL_VERSION}" | grep -Eq '^v?[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z]+)*$'; then \
        comfy ${noninteractive_args} --workspace=/ install --nvidia --skip-torch-or-directml --version "${COMFYUI_INSTALL_VERSION#v}"; \
    else \
        echo "❌ COMFYUI_VERSION must be semver (example: 0.3.39 or v0.3.39)." && exit 1; \
    fi

COPY start.sh /start.sh
COPY install.sh /install.sh
COPY handlers /handlers

RUN chmod +x /start.sh /install.sh

EXPOSE 8188 8888

CMD ["/start.sh"]
