# Proxym-Easy DNS Unlock — self-contained, single runtime image.
# IMPORTANT: build context is unlock/ ONLY:
#   cd unlock && docker build -t proxym-easy-unlock:latest .
#
# Runtime stack:
# - SmartDNS: DNS + DoT
# - sniproxy: SNI HTTP/HTTPS unlock proxy
# - lego: Let's Encrypt DNS-01 certificate/renewal via Cloudflare API token
# - cloudflared: optional Zero Trust Tunnel, periodically restarted
# - nftables/iptables: source IP/CIDR ACL

FROM debian:bookworm-slim

ARG SMARTDNS_RELEASE=Release48.3
ARG SMARTDNS_VERSION=1.2026.07.28-0446
ARG LEGO_VERSION=v5.3.1
ARG CLOUDFLARED_VERSION=2026.7.3

ENV DEBIAN_FRONTEND=noninteractive \
    UNLOCK_ROOT=/opt/unlock \
    CONF_DIR=/etc/unlock \
    RUNTIME_DIR=/run/unlock \
    TZ=Asia/Shanghai

# Keep package layer small: all protocol servers are downloaded static binaries.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl wget openssl procps iproute2 iptables nftables \
      sniproxy python3 \
    && rm -rf /var/lib/apt/lists/*

# Official SmartDNS release — actual x86_64 and aarch64 asset names.
RUN set -eu; \
    case "$(dpkg --print-architecture)" in \
      amd64) sd_arch=x86_64 ;; \
      arm64) sd_arch=aarch64 ;; \
      *) echo "Unsupported SmartDNS architecture: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    url="https://github.com/pymumu/smartdns/releases/download/${SMARTDNS_RELEASE}/smartdns.${SMARTDNS_VERSION}.${sd_arch}-linux-all.tar.gz"; \
    mkdir -p /tmp/smartdns && cd /tmp/smartdns; \
    wget -q -O smartdns.tgz "$url"; \
    tar zxf smartdns.tgz; \
    # Release layout: /usr/sbin/smartdns is a runner; it needs its sibling
    # bundled loader/libs under /usr/local/lib/smartdns. Copy the full runtime.
    runtime="$(find . -type d -path '*/usr/local/lib/smartdns' | head -n1)"; \
    test -n "$runtime" && test -x "$runtime/run-smartdns" && test -x "$runtime/smartdns"; \
    mkdir -p /usr/local/lib/smartdns; \
    cp -a "$runtime"/. /usr/local/lib/smartdns/; \
    # Keep the runner beside smartdns + bundled musl loader/libs. A copied
    # wrapper would resolve its own directory as /usr/local/sbin and fail.
    ln -sf /usr/local/lib/smartdns/run-smartdns /usr/local/sbin/smartdns; \
    /usr/local/sbin/smartdns -v; \
    rm -rf /tmp/smartdns

# lego is a small static ACME DNS-01 client. It avoids Certbot's Python runtime.
RUN set -eu; \
    case "$(dpkg --print-architecture)" in \
      amd64) lego_arch=amd64 ;; \
      arm64) lego_arch=arm64 ;; \
      *) echo "Unsupported lego architecture: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    url="https://github.com/go-acme/lego/releases/download/${LEGO_VERSION}/lego_${LEGO_VERSION}_linux_${lego_arch}.tar.gz"; \
    mkdir -p /tmp/lego && cd /tmp/lego; \
    wget -q -O lego.tgz "$url"; \
    tar zxf lego.tgz; \
    install -m 0755 lego /usr/local/bin/lego; \
    lego --version; \
    rm -rf /tmp/lego

# cloudflared is optional at runtime but present for Zero Trust tunnel support.
RUN set -eu; \
    case "$(dpkg --print-architecture)" in \
      amd64) cf_arch=amd64 ;; \
      arm64) cf_arch=arm64 ;; \
      *) echo "Unsupported cloudflared architecture: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    url="https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-${cf_arch}"; \
    wget -q -O /usr/local/bin/cloudflared "$url"; \
    chmod 0755 /usr/local/bin/cloudflared; \
    cloudflared --version

# App copy intentionally receives ONLY the unlock/ build context.
WORKDIR /opt/unlock
COPY . /opt/unlock/

RUN chmod +x /opt/unlock/scripts/*.sh \
    && mkdir -p /etc/unlock /run/unlock /var/log/unlock \
    && /opt/unlock/scripts/gen-domains.sh \
    && test -s /opt/unlock/domains/all.txt

# Defaults only. Actual ports are configurable at runtime.
EXPOSE 53/udp 53/tcp 853/tcp 80/tcp 443/tcp

HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=3 \
  CMD ["/opt/unlock/scripts/healthcheck.sh"]

ENTRYPOINT ["/opt/unlock/scripts/entrypoint.sh"]
