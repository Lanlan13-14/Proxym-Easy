# syntax=docker/dockerfile:1
# Multi-stage: build unlock-center (Rust) + runtime with lego for LE+CF DNS-01.

ARG RUST_VERSION=1.85
ARG LEGO_VERSION=v5.3.1

FROM rust:${RUST_VERSION}-bookworm AS builder
WORKDIR /src
# Cache deps
COPY Cargo.toml Cargo.lock rust-toolchain.toml ./
COPY crates ./crates
RUN cargo build -p unlock-center --release

FROM debian:bookworm-slim

LABEL org.opencontainers.image.title="Proxym-Easy Unlock Center"
LABEL org.opencontainers.image.description="DNS unlock control plane: DoH/DoT/DNS scheduling + GeoIP nearest + LE CF DNS-01"
LABEL org.opencontainers.image.source="https://github.com/Lanlan13-14/Proxym-Easy/tree/main/unlock-center"

ARG LEGO_VERSION=v5.3.1
ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Shanghai \
    CENTER_ROOT=/opt/unlock-center \
    DATA_DIR=/data \
    CONF_DIR=/etc/unlock-center \
    RUNTIME_DIR=/run/unlock-center

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl openssl python3 gzip tar \
    && rm -rf /var/lib/apt/lists/*

# lego for Let's Encrypt Cloudflare DNS-01 (amd64 + arm64)
RUN set -eu; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) lego_arch=amd64 ;; \
      arm64) lego_arch=arm64 ;; \
      *) echo "unsupported arch $arch" >&2; exit 1 ;; \
    esac; \
    url="https://github.com/go-acme/lego/releases/download/${LEGO_VERSION}/lego_${LEGO_VERSION}_linux_${lego_arch}.tar.gz"; \
    curl -fsSL "$url" -o /tmp/lego.tgz; \
    tar -xzf /tmp/lego.tgz -C /tmp; \
    mv /tmp/lego /usr/local/bin/lego; \
    chmod +x /usr/local/bin/lego; \
    lego --version; \
    rm -rf /tmp/lego.tgz

COPY --from=builder /src/target/release/unlock-center /opt/unlock-center/bin/unlock-center
COPY scripts/ /opt/unlock-center/scripts/
COPY domains/ /opt/unlock-center/domains/
COPY nodes.example.toml config.example.toml /opt/unlock-center/
RUN chmod +x /opt/unlock-center/scripts/*.sh \
    && mkdir -p /data/tls /data/geoip /etc/unlock-center /run/unlock-center /var/log/unlock-center

WORKDIR /opt/unlock-center
EXPOSE 53/udp 53/tcp 853/tcp 443/tcp
ENTRYPOINT ["/opt/unlock-center/scripts/entrypoint.sh"]
