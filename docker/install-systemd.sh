#!/usr/bin/env bash
#
# Installs MTProxy (from this repo's Docker image) as a systemd service,
# together with a daily-restart timer that refreshes Telegram's DC config.
#
# Installed units:
#   MTProxy.service        runs the Docker container
#   MTProxy-reload.timer   restarts MTProxy daily at 04:00 to re-download
#                          proxy-multi.conf (the binary cannot reload it in place)
#
# Settings live in /etc/mtproxy.env (created here, mode 600). The client secret
# is generated once and kept across restarts and re-runs of this script.
#
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

UNIT_DIR=/etc/systemd/system
ENV_FILE=/etc/mtproxy.env
CONTAINER_NAME=mtproxy

die() { echo "error: $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: sudo docker/install-systemd.sh [options]

Options:
  --secret HEX      client secret: exactly 32 hex chars (a "dd" prefix goes
                    into the tg:// link, not here). [default: generated once]
  --tag TAG         proxy tag received from @MTProxybot
  --workers N       number of worker processes (-M) [default: 1]
  --port N          client port inside the container (-H) [default: 443]
  --host-port N     published host port [default: same as --port]
  --stats-port N    stats port inside the container (-p) [default: 8888]
  --image NAME      docker image to run [default: mtproxy:latest]
  --no-build        do not build the image, use --image as-is
  --no-start        install and enable units, but do not start them now
  --uninstall       stop and remove the systemd units
  -h, --help        show this help

To change settings later, edit /etc/mtproxy.env and run:
  systemctl restart MTProxy
EOF
}

rand_hex16() {
  if command -v xxd >/dev/null 2>&1; then
    head -c 16 /dev/urandom | xxd -ps
  else
    head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}

declare -A CLI=()
UNINSTALL=0
NO_BUILD=0
NO_START=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --secret)     CLI[SECRET]="$2"; shift 2 ;;
    --tag)        CLI[TAG]="$2"; shift 2 ;;
    --workers)    CLI[WORKERS]="$2"; shift 2 ;;
    --port)       CLI[CLIENT_PORT]="$2"; CLI[HOST_PORT]="$2"; shift 2 ;;
    --host-port)  CLI[HOST_PORT]="$2"; shift 2 ;;
    --stats-port) CLI[STATS_PORT]="$2"; shift 2 ;;
    --image)      CLI[IMAGE]="$2"; shift 2 ;;
    --no-build)   NO_BUILD=1; shift ;;
    --no-start)   NO_START=1; shift ;;
    --uninstall)  UNINSTALL=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *)            die "unknown option: $1 (try --help)" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "must run as root: sudo $0 $*"

if [[ $UNINSTALL -eq 1 ]]; then
  systemctl disable --now MTProxy-reload.timer MTProxy.service 2>/dev/null || true
  rm -f "$UNIT_DIR/MTProxy.service" "$UNIT_DIR/MTProxy-reload.service" "$UNIT_DIR/MTProxy-reload.timer"
  systemctl daemon-reload
  echo "systemd units removed (docker image and $ENV_FILE left in place)"
  exit 0
fi

command -v docker >/dev/null || die "docker not found in PATH"
command -v systemctl >/dev/null || die "systemctl not found in PATH"
docker info >/dev/null 2>&1 || die "docker daemon is not running"
DOCKER_BIN=$(command -v docker)
SYSTEMCTL_BIN=$(command -v systemctl)

# defaults
SECRET=
TAG=
WORKERS=1
CLIENT_PORT=443
HOST_PORT=443
STATS_PORT=8888
IMAGE=mtproxy:latest

# values from a previous install win over defaults ...
if [[ -f $ENV_FILE ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  echo "loaded existing settings from $ENV_FILE"
fi

# ... and command line wins over everything
if [[ ${#CLI[@]} -gt 0 ]]; then
  for key in "${!CLI[@]}"; do
    printf -v "$key" '%s' "${CLI[$key]}"
  done
fi

if [[ -z $SECRET ]]; then
  SECRET=$(rand_hex16)
  echo "generated new client secret: $SECRET"
fi

[[ $SECRET =~ ^[0-9a-fA-F]{32}$ ]] \
  || die "secret must be exactly 32 hex chars (mtproto-proxy's -S accepts no 'dd' prefix; that goes into the tg:// link only)"
[[ $WORKERS =~ ^[1-9][0-9]*$ ]] || die "--workers must be a positive integer"
for port in "$CLIENT_PORT" "$HOST_PORT" "$STATS_PORT"; do
  [[ $port =~ ^[0-9]+$ ]] || die "ports must be numbers"
done
# TAG and IMAGE are interpolated unescaped into /etc/mtproxy.env, which is later
# both `source`d by this script (as root) and parsed by systemd's EnvironmentFile
# (with ${IMAGE} expanded into ExecStart). Restrict them to safe character sets so
# a newline, space, or shell/systemd metacharacter can't inject extra lines or
# arguments. TAG must match what mtproto-proxy's -P accepts: exactly 32 hex chars.
[[ -z $TAG || $TAG =~ ^[0-9a-fA-F]{32}$ ]] \
  || die "--tag must be exactly 32 hex chars (the proxy tag from @MTProxybot)"
[[ $IMAGE =~ ^[A-Za-z0-9._/@:-]+$ ]] \
  || die "--image must be a docker image reference (letters, digits, and . _ / @ : - only)"

if [[ $NO_BUILD -eq 0 ]]; then
  echo "building image '$IMAGE' from $REPO_ROOT ..."
  docker build -t "$IMAGE" "$REPO_ROOT"
fi

umask 077
cat > "$ENV_FILE" <<EOF
# MTProxy configuration, read by the MTProxy systemd unit.
# Edit and run: systemctl restart MTProxy
SECRET=$SECRET
TAG=$TAG
WORKERS=$WORKERS
CLIENT_PORT=$CLIENT_PORT
HOST_PORT=$HOST_PORT
STATS_PORT=$STATS_PORT
IMAGE=$IMAGE
EOF
echo "wrote $ENV_FILE (mode 600)"

for unit in MTProxy.service MTProxy-reload.service MTProxy-reload.timer; do
  sed -e "s|@DOCKER@|$DOCKER_BIN|g" -e "s|@SYSTEMCTL@|$SYSTEMCTL_BIN|g" \
    "$SCRIPT_DIR/units/$unit" > "$UNIT_DIR/$unit"
done
systemctl daemon-reload
systemctl enable MTProxy.service MTProxy-reload.timer >/dev/null 2>&1
echo "installed $UNIT_DIR/MTProxy.service, MTProxy-reload.service, MTProxy-reload.timer"

if [[ $NO_START -eq 1 ]]; then
  echo "units enabled but not started (--no-start); start with: systemctl start MTProxy"
else
  systemctl restart MTProxy.service
  systemctl restart MTProxy-reload.timer

  if ! systemctl is-active --quiet MTProxy.service; then
    echo "warning: MTProxy.service is not active yet; check: journalctl -u MTProxy" >&2
  fi
fi

cat <<EOF

MTProxy is installed.

  client secret : $SECRET
  host port     : $HOST_PORT
  share link    : tg://proxy?server=YOUR_SERVER&port=$HOST_PORT&secret=$SECRET
  with padding  : tg://proxy?server=YOUR_SERVER&port=$HOST_PORT&secret=dd$SECRET

Next steps:
  1. Register the proxy with @MTProxybot and put the received tag into
     TAG=... in $ENV_FILE
  2. Apply any config change with: systemctl restart MTProxy
  3. Stats: docker exec $CONTAINER_NAME curl -fsS http://127.0.0.1:$STATS_PORT/stats

Daily config refresh: MTProxy-reload.timer restarts the service at 04:00.
Verify with: systemctl list-timers MTProxy-reload.timer
EOF
