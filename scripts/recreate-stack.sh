#!/bin/sh
#
# recreate-stack.sh — force-recreate this BillionMail stack.
#
# RUN THIS AFTER A DEPLOY, or on a timer with --if-stale.
#
#   scripts/recreate-stack.sh              always recreate
#   scripts/recreate-stack.sh --if-stale   recreate only when the config is stale
#
# --if-stale is safe to run from cron: it costs one `ls` in the dovecot container
# when healthy, and only acts when a container is actually reading an empty
# configuration directory. Suggested entry (one-time setup on the host):
#
#   */5 * * * * root /etc/dokploy/compose/<project>/code/scripts/recreate-stack.sh --if-stale >> /var/log/bm-recreate.log 2>&1
#
# WHY IT IS NEEDED
# ----------------
# This compose delivers configuration through *relative* bind mounts into the git
# checkout (./conf/dovecot/conf.d, ./conf/postfix/main.cf, ./logs/...). Deploying
# replaces that checkout directory, but Docker Compose only recreates the services
# whose configuration changed. Every other container keeps its old bind mount --
# which now points at the DELETED directory -- and therefore sees an empty config.
#
# The symptoms are confusing and unrelated-looking:
#
#   dovecot : "doveconf: Fatal: ... No matches"            -> "* BYE Auth process broken"
#             -> Roundcube: "Connection to storage server failed"
#   postfix : warning: open "pgsql" configuration "/etc/postfix/sql/*.cf": No such file
#             -> local recipient resolution broken
#   core    : file watcher "/opt/billionmail/logs/postfix" does not exist
#
# Recreating the containers re-resolves those paths against the new checkout.
#
# The project name is read from a container label rather than assumed, so this can
# never accidentally create a SECOND stack (which would use fresh volumes) -- the
# compose file's own `name:` differs from the platform's project name.
#
set -eu

MATCH="${MATCH:--core-billionmail-1}"
DOV_MATCH="${DOV_MATCH:--dovecot-billionmail-1}"
IF_STALE=0
[ "${1:-}" = "--if-stale" ] && IF_STALE=1

# Detect the stale-config condition.
#
# A DIRECTORY bind mount into the checkout goes EMPTY after a deploy: the
# directory's entries are unlinked while every container keeps the old inode.
# FILE mounts keep working, because a file's inode survives while it is still
# referenced -- which is exactly why dovecot reads its dovecot.conf happily and
# then dies on "!include conf.d/*.conf" with "No matches". That asymmetry is the
# signature of this whole failure class.
#
# dovecot's conf.d carries ~28 tracked files whenever the mount is healthy, so an
# empty one is unambiguous -- and free of false positives, which matters because
# recreating the stack restarts the mail services.
is_stale() {
    _dov=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -- "$DOV_MATCH" | head -1 || true)
    [ -n "$_dov" ] || return 1
    _n=$(docker exec "$_dov" sh -c 'ls /etc/dovecot/conf.d 2>/dev/null | wc -l' 2>/dev/null || echo 0)
    [ "${_n:-0}" -lt 5 ] && return 0
    return 1
}

info=$(docker ps -a \
    --format '{{.Names}}\t{{.Label "com.docker.compose.project"}}\t{{.Label "com.docker.compose.project.working_dir"}}' \
    | grep -- "$MATCH" | head -1 || true)

if [ -z "$info" ]; then
    echo "error: no container matching '$MATCH' found" >&2
    exit 1
fi

name=$(printf '%s' "$info" | cut -f1)
project=$(printf '%s' "$info" | cut -f2)
workdir=$(printf '%s' "$info" | cut -f3)

if [ -z "$project" ] || [ -z "$workdir" ]; then
    echo "error: could not determine project/workdir from $name" >&2
    exit 1
fi

if [ "$IF_STALE" = "1" ]; then
    if is_stale; then
        echo "stale configuration detected (container config directories are empty)"
    else
        echo "configuration is current; nothing to do"
        exit 0
    fi
fi

echo "container : $name"
echo "project   : $project"
echo "workdir   : $workdir"
echo

[ -f "$workdir/docker-compose.yml" ] || { echo "error: no docker-compose.yml in $workdir" >&2; exit 1; }

cd "$workdir"
echo "==> docker compose -p $project up -d --force-recreate"
docker compose -p "$project" up -d --force-recreate

echo
echo "==> verification"
dov=$(docker ps --format '{{.Names}}' | grep -- '-dovecot-billionmail-1' | head -1 || true)
pfx=$(docker ps --format '{{.Names}}' | grep -- '-postfix-billionmail-1' | head -1 || true)

if [ -n "$dov" ]; then
    printf 'dovecot config : '
    docker exec "$dov" dovecot -n >/dev/null 2>&1 && echo "OK" || echo "STILL BROKEN"
    printf 'imap banner    : '
    timeout 5 bash -c 'exec 3<>/dev/tcp/127.0.0.1/143; head -c 120 <&3' 2>/dev/null || echo "(no response)"
    echo
fi

if [ -n "$pfx" ]; then
    printf 'postfix maps   : %s (expect 6 or more)\n' "$(docker exec "$pfx" sh -c 'ls /etc/postfix/sql/ 2>/dev/null | wc -l')"
fi
