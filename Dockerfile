FROM runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404

ENV PYTHONUNBUFFERED=1
WORKDIR /
ARG COMFYUI_REF=main
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
    git clone https://github.com/comfyanonymous/ComfyUI.git /ComfyUI && \
    cd /ComfyUI && \
    git fetch --tags --force && \
    git checkout "${COMFYUI_REF}" && \
    python3 -m pip install --no-cache-dir -r /ComfyUI/requirements.txt

COPY start.sh /start.sh
COPY install.sh /install.sh
COPY handlers /handlers

RUN chmod +x /start.sh /install.sh

EXPOSE 8188 8888

CMD ["/start.sh"]
