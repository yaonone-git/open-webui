FROM ghcr.io/open-webui/open-webui:main
RUN apt-get update && apt-get upgrade -y


ENV PORT=80
EXPOSE 80
USER 10014
