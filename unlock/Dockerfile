FROM debian:bookworm-slim

LABEL org.opencontainers.image.title="Proxym-Easy DNS Unlock"
LABEL org.opencontainers.image.description="SmartDNS DoT + sniproxy with mandatory Cloudflare Zero Trust WARP egress"
LABEL org.opencontainers.image.source="https://github.com/Lanlan13-14/Proxym-Easy/tree/main/unlock"

ARG SMARTDNS_RELEASE=Release48.3
ARG SMARTDNS_VERSION=1.2026.07.28-0446
ARG LEGO_VERSION=v5.3.1
ARG WARP_VERSION=2026.6.880.0

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Shanghai \
    UNLOCK_ROOT=/opt/unlock \
    CONF_DIR=/etc/unlock \
    RUNTIME_DIR=/run/unlock

# Headless-only dependencies. Do not install the WARP GUI/WebKit package.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl wget openssl procps iproute2 iptables nftables \
      dbus libdbus-1-3 libnss3 libnspr4 libpcap0.8 libtss2-esys-3.0.2-0 \
      libtss2-tctildr0 libgcc-s1 sniproxy dnsutils \
    && rm -rf /var/lib/apt/lists/*

# SmartDNS official self-contained runtime, amd64 + arm64.
RUN set -eu; \
    case "$(dpkg --print-architecture)" in \
      amd64) sd_arch="x86_64" ;; \
      arm64) sd_arch="aarch64" ;; \
      *) echo "unsupported SmartDNS architecture" >&2; exit 1 ;; \
    esac; \
    mkdir -p /tmp/smartdns && cd /tmp/smartdns; \
    url="https://github.com/pymumu/smartdns/releases/download/${SMARTDNS_RELEASE}/smartdns.${SMARTDNS_VERSION}.${sd_arch}-linux-all.tar.gz"; \
    wget -q -O smartdns.tgz "$url"; tar zxf smartdns.tgz; \
    runtime="$(find . -type d -path '*/usr/local/lib/smartdns' | head -n1)"; \
    test -x "$runtime/run-smartdns" && test -x "$runtime/smartdns"; \
    mkdir -p /usr/local/lib/smartdns; cp -a "$runtime"/. /usr/local/lib/smartdns/; \
    ln -sf /usr/local/lib/smartdns/run-smartdns /usr/local/sbin/smartdns; \
    smartdns -v; rm -rf /tmp/smartdns

# lego: lightweight Let's Encrypt DNS-01 client for Cloudflare DNS.
RUN set -eu; \
    case "$(dpkg --print-architecture)" in amd64) a=amd64 ;; arm64) a=arm64 ;; esac; \
    mkdir -p /tmp/lego && cd /tmp/lego; \
    wget -q -O lego.tgz "https://github.com/go-acme/lego/releases/download/${LEGO_VERSION}/lego_${LEGO_VERSION}_linux_${a}.tar.gz"; \
    tar zxf lego.tgz; install -m 0755 lego /usr/local/bin/lego; lego --version; rm -rf /tmp/lego

# Official Cloudflare One Client core only. Extract warp-svc + warp-cli from the
# vendor package and omit the ~50MB GUI/taskbar assets. Both amd64/arm64 exist.
RUN set -eu; \
    arch="$(dpkg --print-architecture)"; \
    url="https://pkg.cloudflareclient.com/pool/bookworm/main/c/cloudflare-warp/cloudflare-warp_${WARP_VERSION}_${arch}.deb"; \
    wget -q -O /tmp/cloudflare-warp.deb "$url"; \
    dpkg-deb --fsys-tarfile /tmp/cloudflare-warp.deb \
      | tar -xOf - ./bin/warp-svc > /usr/local/bin/warp-svc; \
    dpkg-deb --fsys-tarfile /tmp/cloudflare-warp.deb \
      | tar -xOf - ./bin/warp-cli > /usr/local/bin/warp-cli; \
    chmod 0755 /usr/local/bin/warp-svc /usr/local/bin/warp-cli; \
    rm -f /tmp/cloudflare-warp.deb; \
    /usr/local/bin/warp-cli --version

WORKDIR /opt/unlock
COPY . /opt/unlock/

# tests/ is intentionally excluded by .dockerignore; only runtime scripts are
# made executable inside the image.
RUN chmod +x /opt/unlock/scripts/*.sh \
    && mkdir -p /etc/unlock /run/unlock /var/log/unlock /var/lib/cloudflare-warp /dev/net
# /dev/net/tun is created at runtime after Docker grants MKNOD + cgroup access.

HEALTHCHECK --interval=30s --timeout=15s --start-period=180s --retries=3 \
  CMD ["/opt/unlock/scripts/healthcheck.sh"]

# Plain DNS/53 remains internal. Public service ports: DoT + transparent SNI.
EXPOSE 853/tcp 80/tcp 443/tcp
ENTRYPOINT ["/opt/unlock/scripts/entrypoint.sh"]
