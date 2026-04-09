#!/bin/bash

# Launch S3 offloader in background once workspace is ready
(
  while [ ! -d /workspace/comfyui_S3_offloader ]; do sleep 2; done
  pip install flask boto3 python-dotenv -q
  cd /workspace/comfyui_S3_offloader
  python3 app.py &>> /workspace/s3_offloader.log
) &

# Hand off to original start.sh
exec /start.sh
