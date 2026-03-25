# Start from the official Runpod PyTorch + CUDA base image.
FROM runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404

# Ensure Python logs are flushed immediately for easier debugging.
ENV PYTHONUNBUFFERED=1
# Use root as the default working directory for startup scripts.
WORKDIR /

# System tools used by start.sh and common custom node installs.
RUN apt-get update --yes && \
    DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends \
    git \
    curl \
    aria2 \
    wget \
    zip \
    libgoogle-perftools4 && \
    rm -rf /var/lib/apt/lists/*

# Copy dependency pins into a temp location to leverage Docker layer caching.
COPY requirements.txt /tmp/requirements.txt

# Upgrade pip and install Python dependencies required by this template.
RUN pip install --no-cache-dir --upgrade pip && \
    grep -v "SageAttention.git" /tmp/requirements.txt > /tmp/requirements.image.txt && \
    pip install --no-cache-dir -r /tmp/requirements.image.txt

# Bundle the ComfyUI source tree into the container image.
COPY ComfyUI /ComfyUI

# Install the template bootstrap script at a dedicated runtime path.
COPY start.sh /opt/template-start.sh

# Install the wrapper startup script that preserves Runpod base services.
COPY run.sh /run.sh

# Make sure the startup script is executable at container launch.
RUN chmod +x /run.sh /opt/template-start.sh

# Document the ComfyUI and Jupyter ports used by this template.
EXPOSE 8188 8888

# Start base services (including SSH) and then run template bootstrap.
CMD ["/run.sh"]
