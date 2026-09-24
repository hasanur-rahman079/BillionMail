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
# There is no handling of surrounding quotes, inline comments or escapes.
#
# Docker Compose, however, DOES unquote when it interpolates ${VAR} from the same
# file. So when the platform writes:
#
#     REDISPASS="s3cret"
#
# Compose gives the redis container `s3cret`, while the core reads the literal
# `"s3cret"` -- quotes included. Redis then rejects every AUTH with:
#
#     WRONGPASS invalid username-password pair or user is disabled
#
# and the core exits and is respawned in a loop, leaving the panel unreachable.
#
# This sidecar rewrites the file with those quotes removed, so both parsers agree.
# It runs on a short interval and re-checks every pass, so it also repairs the file
# after each deploy (the platform rewrites it every time).
#
# The mount is the DIRECTORY containing the env file, not the file itself: a bind
# mount of a single file pins that inode, so after a deploy replaces the file the
# container would keep editing the old one. Accessing it by path avoids that.
#
# The rewrite uses `cat > file` rather than `sed -i`, because sed -i replaces the
# file -- creating a new inode that the *core* container's file bind mount would
# not see. Truncating and rewriting keeps the same inode.
#
set -eu

ENV_FILE="${ENV_FILE:-/checkout/.env}"
CORE_MATCH="${CORE_MATCH:--core-billionmail-1}"
INTERVAL="${INTERVAL:-30}"

log() { echo "[envsync] $(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }

# Strip CR, and surrounding double or single quotes from values.
normalise() {
    sed -e 's/\r$//' \
        -e 's/^\([A-Za-z_][A-Za-z0-9_]*\)="\(.*\)"$/\1=\2/' "$1" \
      | sed -e "s/^\([A-Za-z_][A-Za-z0-9_]*\)='\(.*\)'\$/\1=\2/"
}

restart_core() {
    names=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -- "$CORE_MATCH" || true)
    [ -n "$names" ] || { log "no core container matching '$CORE_MATCH' to restart"; return 0; }
    for c in $names; do
        log "restarting $c so it re-reads the env file"
        docker restart "$c" >/dev/null 2>&1 || log "restart failed for $c"
    done
}

sync_once() {
    if [ ! -f "$ENV_FILE" ]; then
        log "no env file at $ENV_FILE yet; nothing to do"
        return 0
    fi

    tmp=$(mktemp)
    normalise "$ENV_FILE" > "$tmp"

    if cmp -s "$tmp" "$ENV_FILE"; then
        rm -f "$tmp"
        return 0
    fi

    # Report which keys were quoted, without printing their values.
    log "quoted values found in $ENV_FILE: $(grep -E '^[A-Za-z_][A-Za-z0-9_]*=".*"$' "$ENV_FILE" | cut -d= -f1 | tr '\n' ' ')"

    cat "$tmp" > "$ENV_FILE"
    rm -f "$tmp"
    log "env file normalised"
    restart_core
}

log "start: env=$ENV_FILE core-match=$CORE_MATCH interval=${INTERVAL}s"
while :; do
    sync_once || log "sync attempt failed (will retry)"
    sleep "$INTERVAL"
done
