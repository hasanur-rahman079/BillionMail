#!/bin/sh
#
# recreate-stack.sh — force-recreate this BillionMail stack.
#
# RUN THIS AFTER A DEPLOY.
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
