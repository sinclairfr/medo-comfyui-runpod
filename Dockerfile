# Pin to a specific digest for reproducible builds.
# To update: docker pull runpod/comfyui:latest && docker inspect --format='{{index .RepoDigests 0}}' runpod/comfyui:latest
FROM runpod/comfyui:latest

# Pre-install S3 offloader deps at build time — no runtime pip install needed
RUN pip install --no-cache-dir flask boto3 python-dotenv

# Copy and wire up our wrapper
COPY start_wrapper.sh /start_wrapper.sh
RUN chmod +x /start_wrapper.sh

ENTRYPOINT ["/start_wrapper.sh"]
