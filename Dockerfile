FROM runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404

ENV PYTHONUNBUFFERED=1
WORKDIR /

RUN apt-get update --yes && \
    DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends \
    git \
    curl \
    wget \
    zip \
    libgoogle-perftools4 && \
    rm -rf /var/lib/apt/lists/*

COPY ComfyUI/requirements.txt /tmp/requirements.txt

RUN pip install --no-cache-dir --upgrade pip && \
    cp /tmp/requirements.txt /tmp/requirements.image.txt && \
    sed -i -E '/^(torch|torchaudio|torchvision|triton)(==.*)?$/d' /tmp/requirements.image.txt && \
    sed -i -E '/^SQLAlchemy(==.*)?$/d' /tmp/requirements.image.txt && \
    sed -i -E '/^(cuda-bindings|cuda-pathfinder)(==.*)?$/d' /tmp/requirements.image.txt && \
    sed -i -E '/^nvidia-.*-cu12(==.*)?$/d' /tmp/requirements.image.txt && \
    pip install --no-cache-dir --no-build-isolation -r /tmp/requirements.image.txt

COPY ComfyUI /ComfyUI
COPY start.sh /start.sh
COPY handlers /handlers

RUN chmod +x /start.sh

EXPOSE 8188 8888

CMD ["/start.sh"]
