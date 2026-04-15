FROM ghcr.io/open-webui/open-webui:main
RUN apt-get update && apt-get upgrade -y
# 安装 libcap2-bin，允许非 root 绑定特权端口
RUN apt-get install -y libcap2-bin \
    && setcap 'cap_net_bind_service=+ep' $(which python3)
ENV PORT=80
EXPOSE 80
USER 10014
