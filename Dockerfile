# ---- build stage ----
FROM debian:bookworm-slim AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential git ca-certificates \
      libssl-dev zlib1g-dev \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY . .
RUN make && strip objs/bin/mtproto-proxy

# ---- runtime stage ----
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      libssl3 zlib1g curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/mtproxy
COPY --from=build /src/objs/bin/mtproto-proxy /usr/local/bin/mtproto-proxy
COPY docker/entrypoint.sh /entrypoint.sh

# 443 = client connections (-H), stats (-p) is bound to loopback inside the
# container and is deliberately not published.
EXPOSE 443

HEALTHCHECK --interval=1m --timeout=5s --start-period=10s \
  CMD curl -fsS "http://127.0.0.1:${STATS_PORT:-8888}/stats" >/dev/null || exit 1

ENTRYPOINT ["/entrypoint.sh"]
