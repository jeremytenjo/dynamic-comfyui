FROM runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404

ENV PYTHONUNBUFFERED=1
WORKDIR /

# System tools used by start.sh and common custom node installs.
RUN apt-get update --yes && \
    DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends \
    git \
    curl \
    aria2 \
    libgoogle-perftools4 && \
    rm -rf /var/lib/apt/lists/*

COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r /tmp/requirements.txt

COPY ComfyUI /ComfyUI
COPY start.sh /run.sh
RUN chmod +x /run.sh

EXPOSE 8188 8888

# Run this template bootstrap flow via a dedicated startup script.
CMD ["/run.sh"]
