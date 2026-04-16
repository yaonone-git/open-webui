FROM ghcr.io/ztx888/halowebui:main
RUN apt-get update && apt-get upgrade -y
USER 10014
