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
COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 8188 8888

# Keep base image services and run the template bootstrap flow.
CMD ["/start.sh"]
