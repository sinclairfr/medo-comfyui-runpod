#!/bin/bash

# Disable Jupyter before start.sh runs
sed -i 's/start_jupyter$/true/' /start.sh

# Wait for network + workspace, then launch S3 offloader
(
  until curl -sf https://pypi.org > /dev/null 2>&1; do sleep 3; done
  while [ ! -d /workspace/comfyui_S3_offloader ]; do sleep 2; done
  pip install flask boto3 python-dotenv -q
  cd /workspace/comfyui_S3_offloader
  python3 app.py &>> /workspace/s3_offloader.log
) &

exec /start.sh