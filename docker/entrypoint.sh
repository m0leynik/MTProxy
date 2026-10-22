#!/bin/sh
# Entrypoint for the MTProxy container.
#
# Downloads Telegram's connection secret and DC configuration on every start
# (proxy-multi.conf changes occasionally, so it must be refreshed regularly -
# the MTProxy-reload.timer systemd unit restarts the container daily for that),
# then execs mtproto-proxy.
#
# Environment:
#   SECRET        client secret: exactly 32 hex chars, e.g.
#                 $(head -c 16 /dev/urandom | xxd -ps). A "dd" prefix (random
#                 padding) belongs in the tg:// client link only, mtproto-proxy
#                 itself takes the bare 32 hex chars.
#   TAG           optional proxy tag from @MTProxybot (-P)
#   CLIENT_PORT   client-facing port (-H), default 443
#   STATS_PORT    stats port (-p), loopback-only inside the container, default 8888
#   WORKERS       number of worker processes (-M), default 1
#   EXTRA_ARGS    optional extra arguments for mtproto-proxy (word-split)
#   SECRET_URL    where to fetch the Telegram AES password (default core.telegram.org)
#   CONFIG_URL    where to fetch the Telegram DC config (default core.telegram.org)
set -eu

DATA_DIR="${DATA_DIR:-/opt/mtproxy}"
SECRET="${SECRET:-}"
TAG="${TAG:-}"
EXTRA_ARGS="${EXTRA_ARGS:-}"
CLIENT_PORT="${CLIENT_PORT:-443}"
STATS_PORT="${STATS_PORT:-8888}"
WORKERS="${WORKERS:-1}"
SECRET_URL="${SECRET_URL:-https://core.telegram.org/getProxySecret}"
CONFIG_URL="${CONFIG_URL:-https://core.telegram.org/getProxyConfig}"

if [ -z "$SECRET" ]; then
  echo "error: SECRET is not set (exactly 32 hex chars, e.g. \$(head -c 16 /dev/urandom | xxd -ps))" >&2
  exit 2
fi
if [ "${#SECRET}" -ne 32 ]; then
  echo "error: SECRET must be exactly 32 hex chars; a 'dd' prefix goes into the tg:// link only, not here" >&2
  exit 2
fi
case "$SECRET" in
  *[!0-9a-fA-F]*)
    echo "error: SECRET contains non-hex characters" >&2
    exit 2 ;;
esac

cd "$DATA_DIR"

fetch() {
  _attempt=1
  while :; do
    if curl -fsS --max-time 30 "$1" -o "$2"; then
      return 0
    fi
    if [ "$_attempt" -ge 5 ]; then
      echo "error: cannot download $1" >&2
      return 1
    fi
    _attempt=$((_attempt + 1))
    sleep 3
  done
}

fetch "$SECRET_URL" proxy-secret
fetch "$CONFIG_URL" proxy-multi.conf

set -- mtproto-proxy --http-stats -u nobody -p "$STATS_PORT" -H "$CLIENT_PORT" -S "$SECRET" -M "$WORKERS"
if [ -n "$TAG" ]; then
  set -- "$@" -P "$TAG"
fi
if [ -n "$EXTRA_ARGS" ]; then
  # Intentional word splitting: EXTRA_ARGS holds several arguments.
  set -- "$@" $EXTRA_ARGS
fi

echo "starting mtproto-proxy: client port $CLIENT_PORT, stats on loopback port $STATS_PORT"
exec "$@" --aes-pwd proxy-secret proxy-multi.conf
