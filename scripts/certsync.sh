#!/bin/sh
#
# certsync — keep BillionMail's mail TLS certificate in sync with the certificate
# that the reverse proxy (Dokploy's Traefik) already obtains and renews.
#
# WHY THIS EXISTS
# ---------------
# BillionMail issues its own certificates with a hardcoded HTTP-01 challenge
# (core/internal/service/domains/ssl.go -> acme.ApplySSLWithExistingServer(..., "http", ...)).
# Behind Dokploy, Traefik owns port 80 and installs a *global* handler for
# /.well-known/acme-challenge/ on the "web" entrypoint. Traefik answers that path
# for every host it manages and returns 404 for tokens it does not know, without
# falling through to any router. The symptoms in the Traefik log are:
#
#   ERR Cannot retrieve the ACME challenge for mail.example.com (token "...")
#
# So BillionMail's "Apply Free Certificate" can never complete, and no router,
# priority or middleware change can fix it: port 80 cannot be shared.
#
# The fix is to stop competing. Let the proxy own issuance + renewal (it already
# does both), and copy the resulting PEM into the mail services, which read:
#
#   /etc/ssl/mail/cert.pem   and   /etc/ssl/mail/key.pem
#
#   postfix : conf/postfix/main.cf           (smtpd_tls_cert_file / key_file)
#   dovecot : conf/dovecot/conf.d/10-ssl.conf (ssl_cert / ssl_key)
#
# /etc/ssl/mail is the bm-ssl volume (SSL_PATH in core/internal/consts/consts.go).
#
# Because the proxy renews roughly 30 days before expiry and this script copies it
# promptly, the installed cert always has well over 3 days left — so BillionMail's
# own AutoRenewSSL (which fires at <3 days, ssl.go) never triggers and never logs
# failed challenge attempts.
#
# If no acme.json is present (e.g. running without Traefik, where nothing steals
# port 80), this script simply does nothing and BillionMail's own ACME works
# normally.
#
set -eu

# Portable across GNU date and busybox (the sidecar runs on Alpine).
log() { echo "[certsync] $(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }

# Environment values are compared EXACTLY against strings in acme.json. A stray
# CR (CRLF .env), a trailing space or a trailing dot makes the comparison fail
# while looking perfectly correct in any log line -- the certificate is present
# but never matches. Normalise defensively rather than trust the input.
trim() {
    printf '%s' "$1" | tr -d '\r' \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/\.*$//'
}

raw_domain="${CERT_DOMAIN:-}"
ACME_FILE=$(trim "${ACME_FILE:-/acme/acme.json}")
CERT_RESOLVER=$(trim "${CERT_RESOLVER:-letsencrypt}")
CERT_DOMAIN=$(trim "$raw_domain")
SSL_DIR=$(trim "${SSL_DIR:-/ssl}")
INTERVAL=$(trim "${INTERVAL:-3600}")

if [ "$raw_domain" != "$CERT_DOMAIN" ]; then
    log "WARNING: CERT_DOMAIN was not clean; using [$CERT_DOMAIN]."
    log "         raw value, one char per token: $(printf '%s' "$raw_domain" | od -An -c | tr -s ' ')"
    log "         fix BILLIONMAIL_HOSTNAME in .env -- postfix and dovecot receive it too"
fi

if [ -z "$CERT_DOMAIN" ]; then
    log "CERT_DOMAIN is empty (set BILLIONMAIL_HOSTNAME); nothing to do"
    exit 0
fi

# jq is required to read acme.json safely; install it once if the image lacks it.
if ! command -v jq >/dev/null 2>&1; then
    log "installing jq"
    apk add --no-cache jq >/dev/null 2>&1 || { log "FATAL: could not install jq"; exit 1; }
fi

# Extract a PEM value for our domain from Traefik's acme.json.
# Matches on the certificate's primary domain, falling back to SANs.
extract() {
    field="$1"
    # NOTE: jq's stderr is deliberately NOT suppressed -- if the file cannot be
    # read or parsed, the reason must reach the container log instead of being
    # reported as a bare "no certificate".
    jq -r --arg r "$CERT_RESOLVER" --arg d "$CERT_DOMAIN" --arg f "$field" '
        [ .[$r].Certificates[]?
          | select((.domain.main == $d) or (((.domain.sans // []) | index($d)) != null)) ]
        | if length == 0 then empty else .[0][$f] end
    ' "$ACME_FILE" || true
}

# Write $1 to $2 only when the content differs. Sets CHANGED.
install_if_changed() {
    src="$1"; dst="$2"
    mkdir -p "$(dirname "$dst")"
    if [ ! -f "$dst" ] || ! cmp -s "$src" "$dst"; then
        cp "$src" "$dst"
        chmod 644 "$dst"
        CHANGED=1
    fi
}

reload_services() {
    names=$(docker ps --format '{{.Names}}' 2>/dev/null \
        | grep -E 'postfix-billionmail|dovecot-billionmail' || true)
    [ -n "$names" ] || { log "no mail containers found to reload"; return 0; }
    for c in $names; do
        case "$c" in
            *postfix-billionmail*)
                log "reloading postfix in $c"
                docker exec "$c" postfix reload >/dev/null 2>&1 || log "postfix reload failed in $c"
                ;;
            *dovecot-billionmail*)
                log "reloading dovecot in $c"
                docker exec "$c" sh -c 'doveadm reload 2>/dev/null || service dovecot reload' \
                    >/dev/null 2>&1 || log "dovecot reload failed in $c"
                ;;
        esac
    done
}

sync_once() {
    if [ ! -e "$ACME_FILE" ]; then
        log "no acme.json at $ACME_FILE; leaving BillionMail's own ACME alone"
        return 0
    fi

    if [ ! -r "$ACME_FILE" ]; then
        log "acme.json is NOT readable by this container: $(ls -l "$ACME_FILE" 2>&1)"
        return 0
    fi

    log "acme.json: $(wc -c < "$ACME_FILE" | tr -d ' ') bytes; resolvers: $(jq -r 'keys | join(", ")' "$ACME_FILE" 2>/dev/null)"

    cert=$(extract certificate)
    key=$(extract key)

    if [ -z "$cert" ] || [ -z "$key" ]; then
        log "no certificate for $CERT_DOMAIN under resolver '$CERT_RESOLVER' in $ACME_FILE"
        if [ -r "$ACME_FILE" ]; then
            log "resolvers in acme.json: $(jq -r 'keys | join(", ")' "$ACME_FILE" 2>/dev/null || echo '<unparseable>')"
            log "certificates in acme.json: $(jq -r 'to_entries[] | .key as $r | (.value.Certificates // [])[] | "\($r)=\(.domain.main)"' "$ACME_FILE" 2>/dev/null | tr '\n' ' ')"
            log "hint: point CERT_RESOLVER at the resolver that holds $CERT_DOMAIN"
        else
            log "acme.json is not readable by this container"
        fi
        return 0
    fi

    case "$cert" in
        *"BEGIN CERTIFICATE"*) ;;
        *) log "entry for $CERT_DOMAIN exists but is not a PEM certificate; refusing to install"; return 0 ;;
    esac
    case "$key" in
        *"PRIVATE KEY"*) ;;
        *) log "key entry for $CERT_DOMAIN is not a PEM private key; refusing to install"; return 0 ;;
    esac

    tmp=$(mktemp -d)
    printf '%s\n' "$cert" > "$tmp/cert.pem"
    printf '%s\n' "$key"  > "$tmp/key.pem"

    CHANGED=0
    # postfix + dovecot read these two names directly
    install_if_changed "$tmp/cert.pem" "$SSL_DIR/cert.pem"
    install_if_changed "$tmp/key.pem"  "$SSL_DIR/key.pem"
    # BillionMail's own per-domain layout, so its UI/cert checks see the cert
    install_if_changed "$tmp/cert.pem" "$SSL_DIR/$CERT_DOMAIN/fullchain.pem"
    install_if_changed "$tmp/key.pem"  "$SSL_DIR/$CERT_DOMAIN/privkey.pem"
    rm -rf "$tmp"

    if [ "$CHANGED" = 1 ]; then
        log "certificate updated for $CERT_DOMAIN"
        reload_services
    else
        log "certificate unchanged for $CERT_DOMAIN"
    fi
}

# Brackets make hidden characters (e.g. a stray CR from a CRLF .env) visible.
log "start: domain=[$CERT_DOMAIN] resolver=[$CERT_RESOLVER] acme=$ACME_FILE interval=${INTERVAL}s"
while :; do
    sync_once || log "sync attempt failed (will retry)"
    sleep "$INTERVAL"
done
