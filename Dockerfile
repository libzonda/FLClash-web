# syntax=docker/dockerfile:1.7

# ==============================================================================
# Stage 1: Build Native Flutter Web UI (runs natively on $BUILDPLATFORM)
# ==============================================================================
FROM --platform=$BUILDPLATFORM debian:bookworm-slim AS web-builder

ARG FLUTTER_VERSION=stable
ARG SQLITE3_WASM_VERSION=3.7.0

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
     python3 \
    unzip \
    xz-utils \
    zip \
    && rm -rf /var/lib/apt/lists/*

# Install Flutter SDK
ENV FLUTTER_HOME=/opt/flutter
ENV PATH="${FLUTTER_HOME}/bin:${PATH}"
RUN git clone --depth 1 --branch "${FLUTTER_VERSION}" https://github.com/flutter/flutter.git "${FLUTTER_HOME}" \
    || (git clone --depth 1 --branch stable https://github.com/flutter/flutter.git "${FLUTTER_HOME}") \
    && flutter config --no-analytics --enable-web

WORKDIR /workspace
COPY scripts/ ./scripts/
COPY overlay/ ./overlay/
COPY FlClash/ ./FlClash/

# Download sqlite3.wasm for Drift Web SQLite engine if not already present
RUN if [ ! -f /workspace/FlClash/web/sqlite3.wasm ]; then \
      curl -fsSL "https://github.com/simolus3/sqlite3.dart/releases/download/sqlite3-${SQLITE3_WASM_VERSION}/sqlite3.wasm" \
        -o /workspace/FlClash/web/sqlite3.wasm; \
    fi

# Apply non-destructive Web adaptation & compile native Flutter Web bundle
RUN python3 /workspace/scripts/prepare_web.py --apply \
    && cd /workspace/FlClash \
    && flutter pub get \
    && flutter build web --release --no-tree-shake-icons --dart-define=APP_ENV=stable

# ==============================================================================
# Stage 2: Build Go Core + Embedded Web Server Static Binary
# ==============================================================================
FROM --platform=$BUILDPLATFORM golang:bookworm AS core-builder

ARG TARGETOS=linux
ARG TARGETARCH=amd64
ARG GOPROXY="https://goproxy.cn,https://proxy.golang.org,direct"
ENV GOTOOLCHAIN=auto \
    GOPROXY="${GOPROXY}"

WORKDIR /workspace/FlClash/core
COPY FlClash/build_config.yaml /workspace/FlClash/build_config.yaml
COPY FlClash/core/ ./
COPY --from=web-builder /workspace/FlClash/build/web/ ./cmd/flclash-web/web_dist/

RUN TAGS="$(sed -n 's/^tags: *//p' /workspace/FlClash/build_config.yaml || echo 'with_gvisor')" && \
    CGO_ENABLED=0 GOOS="${TARGETOS}" GOARCH="${TARGETARCH}" \
    go build -trimpath -tags "${TAGS}" -ldflags "-w -s" \
    -o /out/FlClash-web ./cmd/flclash-web

# ==============================================================================
# Stage 3: Single-Container Runtime Image (FlClash-web)
# ==============================================================================
FROM alpine:3.20

LABEL org.opencontainers.image.title="FlClash-web" \
      org.opencontainers.image.description="FlClash compiled to native Flutter Web with embedded Clash.Meta (Mihomo) core in a single binary/container"

RUN apk add --no-cache \
    ca-certificates \
    iproute2 \
    iptables \
    nftables \
    tzdata \
    && mkdir -p /data /usr/share/flclash

COPY --from=core-builder /out/FlClash-web /usr/local/bin/FlClash-web

RUN chmod +x /usr/local/bin/FlClash-web && \
    ln -sf /usr/local/bin/FlClash-web /usr/local/bin/FlClash

ENV FLCLASH_WEB_LISTEN="0.0.0.0:9090" \
    FLCLASH_DATA_DIR="/data"

VOLUME ["/data"]

# 9090: FlClash-web UI & WebSocket RPC
# 7890: Clash Mixed / HTTP / SOCKS Proxy Port
EXPOSE 9090 7890

ENTRYPOINT ["/usr/local/bin/FlClash-web"]
CMD ["--listen", "0.0.0.0:9090", "--data-dir", "/data"]

