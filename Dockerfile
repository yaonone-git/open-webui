FROM ghcr.io/ztx888/halowebui:slim
RUN apt-get update && apt-get upgrade -y && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir "Authlib>=1.6.9"
USER 10014
