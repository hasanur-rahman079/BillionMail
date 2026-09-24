#!/bin/sh
#
# envsync — keep the env file readable by BillionMail's parser.
#
# WHY THIS EXISTS
# ---------------
# BillionMail reads .env with a deliberately literal parser
# (core/internal/service/public/common.go:2425):
#
#     env := strings.Split(row, "=")
#     if len(env) == 2 {
#         if strings.TrimSpace(env[0]) == envName {
#             envVal = strings.TrimSpace(env[1])   // <- no unquoting
#
# No handling of surrounding quotes, inline comments or escapes. Compose, however,
# DOES unquote when interpolating ${VAR} from the same file. So when the platform
# writes every value quoted:
#
#     REDISPASS="s3cret"
#
# redis is started requiring `s3cret` while the core authenticates with `"s3cret"`
# -- quotes included -- and Redis answers:
#
#     WRONGPASS invalid username-password pair or user is disabled
#
# The core then exits, supervisord respawns it, and the panel is unreachable.
#
# WHY IT GOES THROUGH THE CORE CONTAINER
# --------------------------------------
# It would be simpler to mount the checkout and edit .env directly, but the
# platform replaces that directory on every deploy: a container bind mount of it
# ends up pointing at the emptied, deleted directory and can no longer see the
# file (observed: "no env file ... yet" repeating forever after a deploy).
#
# The core container is recreated on every deploy, so ITS mount always refers to
# the current file. This sidecar therefore reads and rewrites the file through
# `docker exec`, which needs nothing but the Docker socket. Writing through the
# container's mount also preserves the inode, which matters because the env file
# is itself bind-mounted -- replacing it would leave other readers on the old one.
#
set -eu

ENV_IN_CONTAINER="${ENV_IN_CONTAINER:-/opt/billionmail/.env}"
CORE_MATCH="${CORE_MATCH:--core-billionmail-1}"
INTERVAL="${INTERVAL:-30}"

log() { echo "[envsync] $(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }

# Strip CR, and surrounding double or single quotes from values.
normalise() {
    sed -e 's/\r$//' \
        -e 's/^\([A-Za-z_][A-Za-z0-9_]*\)="\(.*\)"$/\1=\2/' "$1" \
      | sed -e "s/^\([A-Za-z_][A-Za-z0-9_]*\)='\(.*\)'\$/\1=\2/"
}

find_core() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -- "$CORE_MATCH" | head -1 || true
}

sync_once() {
    core=$(find_core)
    if [ -z "$core" ]; then
        log "no core container matching '$CORE_MATCH' is running; nothing to do"
        return 0
    fi

    if ! docker exec "$core" test -f "$ENV_IN_CONTAINER" 2>/dev/null; then
        log "$ENV_IN_CONTAINER not present inside $core yet; nothing to do"
        return 0
    fi

    tmp=$(mktemp); out=$(mktemp)
    if ! docker exec "$core" cat "$ENV_IN_CONTAINER" > "$tmp" 2>/dev/null; then
        log "could not read $ENV_IN_CONTAINER from $core"
        rm -f "$tmp" "$out"
        return 0
    fi

    normalise "$tmp" > "$out"

    if cmp -s "$tmp" "$out"; then
        rm -f "$tmp" "$out"
        return 0
    fi

    # Name the offending keys only -- never their values.
    log "quoted values found: $(grep -E '^[A-Za-z_][A-Za-z0-9_]*=".*"$' "$tmp" | cut -d= -f1 | tr '\n' ' ')"

    # Write back THROUGH the container's mount: same inode, so the bind mount the
    # core itself reads keeps working.
    if docker exec -i "$core" sh -c "cat > $ENV_IN_CONTAINER" < "$out"; then
        log "env file normalised"
        rm -f "$tmp" "$out"
        log "restarting $core so it re-reads the env file"
        docker restart "$core" >/dev/null 2>&1 || log "restart failed for $core"
    else
        log "failed to write $ENV_IN_CONTAINER in $core"
        rm -f "$tmp" "$out"
    fi
}

log "start: env=$ENV_IN_CONTAINER core-match=$CORE_MATCH interval=${INTERVAL}s"
while :; do
    sync_once || log "sync attempt failed (will retry)"
    sleep "$INTERVAL"
done
