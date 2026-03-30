FROM ghcr.io/open-webui/open-webui:main
RUN apt-get update && apt-get upgrade -y
USER 10014
