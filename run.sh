#!/usr/bin/env bash
set -e

# Start Runpod base services (SSH/Jupyter) in the background.
/start.sh &

# Give base services a moment to initialize before custom bootstrap.
sleep 2

# Prevent duplicate Jupyter startup from the template script.
export START_JUPYTER=0

# Run the template-specific bootstrap flow (models, config, ComfyUI).
exec /opt/template-start.sh
