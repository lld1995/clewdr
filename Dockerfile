FROM docker.westsnow.cn/lukemathwalker/cargo-chef:latest-rust-trixie AS frontend-builder
WORKDIR /build
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG http_proxy
ARG https_proxy
RUN rustup target add wasm32-unknown-unknown && \
    curl -L --proto '=https' --tlsv1.2 -sSf https://raw.githubusercontent.com/cargo-bins/cargo-binstall/main/install-from-binstall-release.sh | bash
# Dummy src to satisfy workspace root member
RUN mkdir -p src && echo "fn main() {}" > src/main.rs
COPY Cargo.toml Cargo.lock ./
COPY clewdr-types/ clewdr-types/
COPY clewdr-frontend/ clewdr-frontend/
COPY .cargo/ .cargo/
RUN cargo binstall trunk --no-confirm && \
    cd clewdr-frontend && trunk build --release

FROM docker.westsnow.cn/lukemathwalker/cargo-chef:latest-rust-trixie AS chef
WORKDIR /build

FROM chef AS planner
COPY . .
RUN cargo chef prepare --recipe-path recipe.json

FROM chef AS backend-builder
ARG TARGETARCH

ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG http_proxy
ARG https_proxy
# Install build dependencies + musl toolchain
RUN apt-get update && apt-get install -y \
    build-essential \
    cmake \
    clang \
    libclang-dev \
    perl \
    pkg-config \
    musl-tools \
    upx-ucl \
    && rm -rf /var/lib/apt/lists/*

# Determine musl target from Docker platform
RUN case "$TARGETARCH" in \
    amd64) echo "x86_64-unknown-linux-musl" > /tmp/rust-target ;; \
    arm64) echo "aarch64-unknown-linux-musl" > /tmp/rust-target ;; \
    *) echo "Unsupported arch: $TARGETARCH" && exit 1 ;; \
    esac && \
    rustup target add "$(cat /tmp/rust-target)"

COPY --from=planner /build/recipe.json recipe.json

# Build dependencies - this is the caching Docker layer.
RUN RUST_TARGET=$(cat /tmp/rust-target) && \
    CC=musl-gcc CXX=clang++ \
    cargo chef cook --release --target "$RUST_TARGET" \
    --no-default-features --features embed-resource,xdg \
    --recipe-path recipe.json

# Build application
COPY . .
COPY --from=frontend-builder /build/static/ ./static
RUN RUST_TARGET=$(cat /tmp/rust-target) && \
    CC=musl-gcc CXX=clang++ \
    cargo build --release --target "$RUST_TARGET" \
    --no-default-features --features embed-resource,xdg --bin clewdr \
    && cp ./target/"$RUST_TARGET"/release/clewdr /build/clewdr \
    && upx --best --lzma /build/clewdr \
    && mkdir -p /etc/clewdr/log \
    && touch /etc/clewdr/clewdr.toml

# ============================================================
# Download mihomo binary for the target architecture
# ============================================================
FROM docker.westsnow.cn/library/debian:trixie-slim AS mihomo-fetcher
ARG TARGETARCH
ARG MIHOMO_VERSION=v1.19.10
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG http_proxy
ARG https_proxy
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*
RUN case "$TARGETARCH" in \
    amd64) GOARCH=amd64 ;; \
    arm64) GOARCH=arm64 ;; \
    *) echo "Unsupported arch: $TARGETARCH" && exit 1 ;; \
    esac && \
    curl -fsSL "https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VERSION}/mihomo-linux-${GOARCH}-${MIHOMO_VERSION}.gz" \
    | gzip -d > /usr/local/bin/mihomo && \
    chmod +x /usr/local/bin/mihomo

# ============================================================
# Download s6-overlay for the target architecture
# ============================================================
FROM docker.westsnow.cn/library/debian:trixie-slim AS s6-fetcher
ARG TARGETARCH
ARG S6_VERSION=3.2.0.2
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG http_proxy
ARG https_proxy
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl xz-utils \
    && rm -rf /var/lib/apt/lists/*
RUN case "$TARGETARCH" in \
    amd64) S6ARCH=x86_64 ;; \
    arm64) S6ARCH=aarch64 ;; \
    *) echo "Unsupported arch: $TARGETARCH" && exit 1 ;; \
    esac && \
    curl -fsSL "https://github.com/just-containers/s6-overlay/releases/download/v${S6_VERSION}/s6-overlay-noarch.tar.xz" \
    | tar -Jxp -C / && \
    curl -fsSL "https://github.com/just-containers/s6-overlay/releases/download/v${S6_VERSION}/s6-overlay-${S6ARCH}.tar.xz" \
    | tar -Jxp -C /

# ============================================================
# Final image
# ============================================================
FROM docker.westsnow.cn/library/debian:trixie-slim

# Install ca-certificates for HTTPS
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG http_proxy
ARG https_proxy
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copy s6-overlay runtime
COPY --from=s6-fetcher /command /command
COPY --from=s6-fetcher /package /package
COPY --from=s6-fetcher /etc/s6-overlay /etc/s6-overlay
COPY --from=s6-fetcher /init /init

# Copy clewdr
COPY --from=backend-builder /build/clewdr /usr/local/bin/clewdr
COPY --from=backend-builder /etc/clewdr /etc/clewdr

# Copy mihomo binary and geo data
COPY --from=mihomo-fetcher /usr/local/bin/mihomo /usr/local/bin/mihomo
COPY mihomo-chain/Country.mmdb /etc/mihomo/Country.mmdb
COPY mihomo-chain/geoip.dat    /etc/mihomo/geoip.dat
COPY mihomo-chain/geosite.dat  /etc/mihomo/geosite.dat

# Copy s6 service definitions
COPY s6-services/ /etc/s6-overlay/s6-rc.d/
RUN find /etc/s6-overlay/s6-rc.d -name 'run' -o -name 'finish' | xargs chmod +x

# Entrypoint init script (s6 cont-init.d)
COPY docker-entrypoint.sh /etc/s6-overlay/cont-init.d/00-init.sh
RUN chmod +x /etc/s6-overlay/cont-init.d/00-init.sh

ENV CLEWDR_IP=0.0.0.0
ENV CLEWDR_PORT=8484
ENV CLEWDR_CHECK_UPDATE=FALSE
ENV CLEWDR_AUTO_UPDATE=FALSE
# clewdr 通过内部 mihomo HTTP 代理出站
ENV CLEWDR_PROXY=http://127.0.0.1:17890

EXPOSE 8484

# /etc/clewdr: clewdr 配置和日志
# /etc/mihomo: mihomo config.yaml（可 volume 挂载覆盖）
VOLUME ["/etc/clewdr", "/etc/mihomo"]

ENTRYPOINT ["/init"]