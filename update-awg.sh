#!/usr/bin/env bash
#
# update-awg.sh — safely update the amneziawg-go binary inside an Amnezia container
#                 while fully preserving the server key and all client configs.
#
# Why: the Amnezia desktop app has NO built-in "update protocol, keep configs" option.
# Its only GUI action (Install) recreates the server with a NEW key and breaks every
# config you handed out. This script updates ONLY the daemon binary, leaving the
# server identity (private key + peers + port + obfuscation) untouched. No client
# notices anything except a ~5-second reconnect.
#
# What it does:
#   1. Finds the running AWG container and its config.
#   2. Backs up awg0.conf to the host (server key + all peers).
#   3. Pulls the fresh amneziawg-go image, compares the binary by sha256 (NOT --version!).
#   4. If the binary is newer — commits the current container + rebuilds replacing one file.
#   5. Starts the new container with the same flags, verifies key/peers/NAT.
#   6. Keeps the old container as a rollback (with autostart disabled).
#
# Idempotent: if the binary is already fresh, it changes nothing and exits.
#
# Usage:
#   sudo ./update-awg.sh              # update to :latest
#   sudo ./update-awg.sh 0.2.19       # update to a specific tag
#   sudo ./update-awg.sh --dry-run    # only show what would be done
#
# Requirements: docker, root. Tested on Ubuntu 24.04 + Amnezia self-hosted (AWG 2.0).

set -euo pipefail

# ── settings (overridable via environment variables) ──────────────────────────
UPSTREAM_IMAGE="${UPSTREAM_IMAGE:-amneziavpn/amneziawg-go}"   # upstream image with the binary
UPSTREAM_TAG="${1:-latest}"                                    # tag: latest or 0.2.19 etc.
BIN_PATH="${BIN_PATH:-/usr/bin/amneziawg-go}"                  # binary path inside the container
BACKUP_DIR="${BACKUP_DIR:-/root/awg-backups}"                 # where to store backups
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && { DRY_RUN=1; UPSTREAM_TAG="latest"; }

# ── helpers ───────────────────────────────────────────────────────────────────
c_green='\033[0;32m'; c_red='\033[0;31m'; c_yellow='\033[1;33m'; c_reset='\033[0m'
info()  { echo -e "${c_green}[*]${c_reset} $*"; }
warn()  { echo -e "${c_yellow}[!]${c_reset} $*"; }
die()   { echo -e "${c_red}[x] $*${c_reset}" >&2; exit 1; }
run()   { if [ "$DRY_RUN" = 1 ]; then echo "    (dry-run) $*"; else eval "$*"; fi; }

[ "$(id -u)" = 0 ] || die "Run as root (sudo)."
command -v docker >/dev/null || die "docker not found."

# ── 1. find the running AWG container ─────────────────────────────────────────
# Look for a running container that has awg0.conf inside. The name may vary
# (amnezia-awg2, amnezia-awg, ...), so we don't hardcode it.
info "Looking for a running AWG container..."
CONTAINER=""
for c in $(docker ps --format '{{.Names}}'); do
  if docker exec "$c" test -f /opt/amnezia/awg/awg0.conf 2>/dev/null; then
    CONTAINER="$c"; break
  fi
done
[ -n "$CONTAINER" ] || die "No running container with /opt/amnezia/awg/awg0.conf found. Is Amnezia AWG installed and running?"
info "Container: ${c_yellow}${CONTAINER}${c_reset}"

CONF_IN_CONTAINER="/opt/amnezia/awg/awg0.conf"
IFACE="$(docker exec "$CONTAINER" sh -c 'ls /opt/amnezia/awg/*.conf' | head -1 | xargs -n1 basename | sed 's/\.conf$//')"
IFACE="${IFACE:-awg0}"

# ── 2. back up the config (server key + all peers) ────────────────────────────
mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
STAMP="$(date +%F-%H%M%S)"
BACKUP_FILE="$BACKUP_DIR/awg0.conf.$STAMP"
info "Backing up config -> $BACKUP_FILE"
if [ "$DRY_RUN" = 0 ]; then
  docker exec "$CONTAINER" cat "$CONF_IN_CONTAINER" > "$BACKUP_FILE"
  chmod 600 "$BACKUP_FILE"
  PEERS_BACKUP="$(grep -c '^\[Peer\]' "$BACKUP_FILE" || true)"
  KEY_BACKUP="$(grep -c '^PrivateKey' "$BACKUP_FILE" || true)"
  [ "$KEY_BACKUP" = 1 ] || die "No server key in the backup — aborting, something is wrong."
  info "Backup contains: peers=$PEERS_BACKUP, server key=present."
fi

# also save the old container's run parameters (for reference / rollback)
docker inspect "$CONTAINER" > "$BACKUP_DIR/inspect.$CONTAINER.$STAMP.json" 2>/dev/null || true

# ── 3. extract the fresh binary and compare by sha256 ─────────────────────────
info "Pulling fresh image $UPSTREAM_IMAGE:$UPSTREAM_TAG..."
run "docker pull $UPSTREAM_IMAGE:$UPSTREAM_TAG"

NEW_BIN="$BACKUP_DIR/amneziawg-go.$STAMP"
if [ "$DRY_RUN" = 0 ]; then
  TMP="awg-extract-$STAMP"
  docker create --name "$TMP" "$UPSTREAM_IMAGE:$UPSTREAM_TAG" >/dev/null
  docker cp "$TMP:$BIN_PATH" "$NEW_BIN"
  docker rm "$TMP" >/dev/null
  NEW_SHA="$(sha256sum "$NEW_BIN" | awk '{print $1}')"
  CUR_SHA="$(docker exec "$CONTAINER" sha256sum "$BIN_PATH" | awk '{print $1}')"
  info "Current binary : $CUR_SHA"
  info "Fresh binary   : $NEW_SHA"
  if [ "$NEW_SHA" = "$CUR_SHA" ]; then
    warn "Binary is already up to date — nothing to update. Exiting."
    rm -f "$NEW_BIN"
    exit 0
  fi
  # IMPORTANT: do NOT compare by `--version` — Amnezia hardcodes it (0.2.19 still reports 0.0.20250522).
else
  echo "    (dry-run) would compare binary sha256 and stop if they match"
fi

# ── 4. commit the current container + rebuild replacing one file ──────────────
# commit is needed because the real start.sh (awg-quick up + iptables/NAT) and awg0.conf
# live in the container's WRITABLE LAYER, not in the image. Building from a clean image won't work.
BASE_SNAP="amnezia-awg-updater:snap-$STAMP"
NEW_IMAGE="amnezia-awg-updater:new-$STAMP"
info "Snapshotting current container -> $BASE_SNAP"
run "docker commit $CONTAINER $BASE_SNAP"

info "Building image with only the binary replaced -> $NEW_IMAGE"
if [ "$DRY_RUN" = 0 ]; then
  BUILD_DIR="$(mktemp -d)"
  cp "$NEW_BIN" "$BUILD_DIR/amneziawg-go.new"
  cat > "$BUILD_DIR/Dockerfile" <<EOF
FROM $BASE_SNAP
COPY amneziawg-go.new $BIN_PATH
RUN chmod 755 $BIN_PATH
EOF
  docker build -t "$NEW_IMAGE" "$BUILD_DIR"
  rm -rf "$BUILD_DIR"
  BUILT_SHA="$(docker run --rm --entrypoint sh "$NEW_IMAGE" -c "sha256sum $BIN_PATH" | awk '{print $1}')"
  [ "$BUILT_SHA" = "$NEW_SHA" ] || die "Wrong binary in the built image ($BUILT_SHA). Aborting, the running container is untouched."
  info "Built image has the correct binary: $BUILT_SHA"
fi

# ── 5. read run parameters and recreate the container ─────────────────────────
# Reconstruct docker run from the live inspect so we don't lose port/caps/sysctl/networks.
info "Reading the old container's run parameters..."
if [ "$DRY_RUN" = 0 ]; then
  PORTS="$(docker inspect "$CONTAINER" --format '{{range $p, $conf := .HostConfig.PortBindings}}{{$p}} {{end}}')"
  PORT_ARGS=""
  for p in $PORTS; do
    hostport="$(docker inspect "$CONTAINER" --format "{{(index .HostConfig.PortBindings \"$p\" 0).HostPort}}")"
    proto="${p##*/}"; cport="${p%/*}"
    PORT_ARGS="$PORT_ARGS -p ${hostport}:${cport}/${proto}"
  done
  CAPS="$(docker inspect "$CONTAINER" --format '{{range .HostConfig.CapAdd}}--cap-add={{.}} {{end}}')"
  PRIV="$(docker inspect "$CONTAINER" --format '{{if .HostConfig.Privileged}}--privileged{{end}}')"
  SYSCTLS="$(docker inspect "$CONTAINER" --format '{{range $k,$v := .HostConfig.Sysctls}}--sysctl {{$k}}={{$v}} {{end}}')"
  # extra networks (besides the default bridge) — attach after start
  EXTRA_NETS="$(docker inspect "$CONTAINER" --format '{{range $n, $_ := .NetworkSettings.Networks}}{{$n}} {{end}}' | tr ' ' '\n' | grep -vx 'bridge' || true)"

  info "Stopping the old container (renaming to *-old, NOT deleting — this is the rollback)..."
  docker rename "$CONTAINER" "${CONTAINER}-old-$STAMP"
  docker update --restart=no "${CONTAINER}-old-$STAMP" >/dev/null   # key: so it won't fight for the port after a reboot
  docker stop "${CONTAINER}-old-$STAMP" >/dev/null

  info "Starting the updated container..."
  # shellcheck disable=SC2086
  docker run -d --restart always $PRIV $CAPS $PORT_ARGS \
    -v /lib/modules:/lib/modules $SYSCTLS \
    --name "$CONTAINER" "$NEW_IMAGE" >/dev/null

  for net in $EXTRA_NETS; do
    info "Attaching network: $net"
    docker network connect "$net" "$CONTAINER" 2>/dev/null || warn "  could not attach $net (maybe already attached)"
  done
fi

# ── 6. verify ─────────────────────────────────────────────────────────────────
if [ "$DRY_RUN" = 0 ]; then
  sleep 3
  echo "──────────── VERIFY ────────────"
  RUN_SHA="$(docker exec "$CONTAINER" sha256sum "$BIN_PATH" | awk '{print $1}')"
  PUBKEY="$(docker exec "$CONTAINER" awg show "$IFACE" 2>/dev/null | grep 'public key' | awk '{print $3}')"
  PORT="$(docker exec "$CONTAINER" awg show "$IFACE" 2>/dev/null | grep 'listening port' | awk '{print $3}')"
  PEERS_NOW="$(docker exec "$CONTAINER" awg show "$IFACE" 2>/dev/null | grep -c '^peer' || true)"
  NAT="$(docker exec "$CONTAINER" iptables -t nat -S POSTROUTING 2>/dev/null | grep -c MASQUERADE || true)"
  STATUS="$(docker ps --filter "name=^${CONTAINER}$" --format '{{.Status}}')"

  echo "  binary        : $RUN_SHA $([ "$RUN_SHA" = "$NEW_SHA" ] && echo OK || echo '!! NOT FRESH')"
  echo "  public key    : $PUBKEY"
  echo "  port          : $PORT"
  echo "  peers         : $PEERS_NOW (backup had $PEERS_BACKUP)"
  echo "  NAT MASQUERADE: $NAT rules"
  echo "  status        : $STATUS"
  echo "────────────────────────────────"

  if [ "$RUN_SHA" = "$NEW_SHA" ] && [ -n "$PUBKEY" ] && [ "$NAT" -ge 1 ]; then
    info "${c_green}Update successful.${c_reset} All configs preserved, no need to re-issue anything."
    echo
    echo "Rollback (if something surfaces later):"
    echo "  docker stop $CONTAINER && docker rm $CONTAINER"
    echo "  docker rename ${CONTAINER}-old-$STAMP $CONTAINER && docker update --restart always $CONTAINER && docker start $CONTAINER"
    echo
    echo "Once you're sure it's stable (a day or two), remove the rollback:"
    echo "  docker rm ${CONTAINER}-old-$STAMP"
    echo "Do NOT delete the config backup: $BACKUP_FILE"
  else
    warn "Verification failed! Rolling back to the old container..."
    docker stop "$CONTAINER" 2>/dev/null || true
    docker rm "$CONTAINER" 2>/dev/null || true
    docker rename "${CONTAINER}-old-$STAMP" "$CONTAINER"
    docker update --restart always "$CONTAINER" >/dev/null
    docker start "$CONTAINER" >/dev/null
    die "Rolled back — the old container is running. Nothing lost. Check the logs: docker logs $CONTAINER"
  fi
else
  echo "    (dry-run) here it would verify key/peers/NAT and auto-roll-back on mismatch"
fi
