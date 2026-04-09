FROM runpod/comfyui:latest

COPY start_wrapper.sh /start_wrapper.sh
RUN chmod +x /start_wrapper.sh

ENTRYPOINT ["/start_wrapper.sh"]
