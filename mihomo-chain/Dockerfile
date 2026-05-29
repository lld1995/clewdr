# ============================================================
# Dockerfile - mihomo v1.19.25 链式代理容器
# mihomo 为静态编译二进制，无需任何运行时依赖，使用 scratch 基础镜像
# ============================================================

FROM alpine:latest

# 复制预下载的 mihomo 二进制并赋予执行权限
COPY mihomo /usr/local/bin/mihomo
RUN chmod +x /usr/local/bin/mihomo

# 复制配置文件和 geo 规则文件
COPY config.yaml /etc/mihomo/config.yaml
COPY Country.mmdb /etc/mihomo/Country.mmdb
COPY geoip.dat /etc/mihomo/geoip.dat
COPY geosite.dat /etc/mihomo/geosite.dat

# 环境变量
ENV TZ=Asia/Shanghai

# 暴露端口
EXPOSE 17890/tcp
EXPOSE 17891/tcp
EXPOSE 17892/tcp
EXPOSE 17893/tcp
EXPOSE 17894/tcp
EXPOSE 10053/tcp
EXPOSE 10053/udp
EXPOSE 19090/tcp

# 工作目录
WORKDIR /etc/mihomo

# 启动 mihomo
CMD ["/usr/local/bin/mihomo", "-d", "/etc/mihomo"]
