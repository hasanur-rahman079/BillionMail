#!/bin/sh
#
# install-guard.sh — let the stack install its own deploy guard on the host.
#
# WHY
# ---
# A deploy replaces the git checkout, and the platform only recreates containers
# whose configuration changed. Every other container keeps a DIRECTORY bind mount
# pointing at the now-deleted directory and therefore reads an empty configuration
# (dovecot dies with "No matches" -> "* BYE Auth process broken"). Nothing on the
# platform side prevents this.
#
# scripts/recreate-stack.sh --if-stale repairs it, but somebody has to run it. This
# script removes that "somebody": it writes a cron entry on the HOST pointing at the
# repair script, discovered from this container's own compose labels. A new server
# therefore needs no per-server setup, and nothing is hardcoded -- no project name,
# no paths.
#
# HOW
# ---
# * The compose working directory comes from this container's own
#   com.docker.compose.project.working_dir label, so the cron entry is correct on
#   any server and any project name.
# * The parent of the checkout is mounted (not the checkout itself), because the
#   deploy replaces the checkout but never its parent -- so this container always
#   sees the current scripts/.
# * /etc/cron.d is mounted from the host, which is how the entry gets installed.
#   The stack already mounts the Docker socket, so this adds no new privilege.
#
# Set INSTALL_CRON=0 to disable, or GUARD_SCHEDULE to change the frequency.
#
set -eu

CRON_DIR="${CRON_DIR:-/host-cron}"
STACK_DIR="${STACK_DIR:-/stack}"
SELF="${HOSTNAME:-$(hostname 2>/dev/null || true)}"
SCHEDULE="${GUARD_SCHEDULE:-*/5 * * * *}"
INSTALL="${INSTALL_CRON:-1}"
CHECK_EVERY="${GUARD_RECHECK:-3600}"
CRON_FILE="$CRON_DIR/bm-recreate"

log() { echo "[guard] $(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }

compose_workdir() {
    [ -n "$SELF" ] || return 1
    docker inspect "$SELF" \
        --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null
}

install_once() {
    [ "$INSTALL" = "1" ] || { log "INSTALL_CRON=0; not installing a guard"; return 0; }

    workdir=$(compose_workdir || true)
    if [ -z "$workdir" ] || [ "$workdir" = "<no value>" ]; then
        log "could not read com.docker.compose.project.working_dir from this container; skipping"
        return 0
    fi

    # The parent of the checkout is stable, so resolve the script through the mount
    # rather than trusting the label's absolute path.
    dir=${workdir##*/}
    script="$STACK_DIR/$dir/scripts/recreate-stack.sh"

    if [ ! -f "$script" ]; then
        log "$script not found (is the parent of the checkout mounted at $STACK_DIR?); skipping"
        return 0
    fi

    if [ ! -d "$CRON_DIR" ]; then
        log "$CRON_DIR is not a directory (mount /etc/cron.d there); skipping"
        return 0
    fi

    tmp=$(mktemp)
    cat > "$tmp" <<EOF
# Installed by the BillionMail stack (guard-billionmail).
# A deploy replaces the checkout; containers the platform does not recreate then
# read an empty configuration directory. This repairs that automatically.
#
# Harmless when the stack is healthy: --if-stale exits without doing anything.
$SCHEDULE root $script --if-stale >> /var/log/bm-recreate.log 2>&1
EOF

    if [ -f "$CRON_FILE" ] && cmp -s "$tmp" "$CRON_FILE"; then
        rm -f "$tmp"
        return 0
    fi

    cat "$tmp" > "$CRON_FILE"
    chmod 644 "$CRON_FILE"
    rm -f "$tmp"
    log "installed $CRON_FILE:"
    log "  $SCHEDULE root $script --if-stale"
}

install_once
while :; do
    sleep "$CHECK_EVERY"
    install_once || log "guard check failed"
done
