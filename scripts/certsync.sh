#!/bin/sh
#
# certsync — keep BillionMail's TLS certificates in sync with the certificates the
# reverse proxy (Dokploy's Traefik) already obtains and renews.
#
# WHY THIS EXISTS
# ---------------
# BillionMail issues its own certificates with a hardcoded HTTP-01 challenge
# (core/internal/service/domains/ssl.go -> ApplySSLWithExistingServer(..., "http", ...)).
#
# Behind Dokploy that can never work. Traefik owns port 80 and installs a *global*
# handler for /.well-known/acme-challenge/ on the "web" entrypoint. It answers that
# path for every host it manages, returns 404 for tokens it does not know, and does
# NOT fall through to any router. The tell-tale line in the Traefik log is:
#
#   ERR Cannot retrieve the ACME challenge for mail.example.com (token "...")
#
# So the UI's "Apply Free Certificate" always ends in a 404, and no router, priority
# or middleware change can fix it: port 80 cannot be shared. Instead of competing,
# this sidecar lets the proxy own issuance AND renewal and copies the results in.
#
# WHAT IT DOES
# ------------
# For EVERY certificate in the proxy's acme.json it writes BillionMail's per-domain
# layout:
#
#   /etc/ssl/mail/<domain>/fullchain.pem
#   /etc/ssl/mail/<domain>/privkey.pem
#
# and for the primary mail hostname (CERT_DOMAIN) also the two files the mail
# daemons read directly:
#
#   /etc/ssl/mail/cert.pem      postfix: conf/postfix/main.cf
#   /etc/ssl/mail/key.pem       dovecot: conf/dovecot/conf.d/10-ssl.conf
#
# /etc/ssl/mail is the bm-ssl volume (SSL_PATH in core/internal/consts/consts.go).
# Whenever anything changes, postfix and dovecot are reloaded.
#
# Because BillionMail's getSSLInfo (mail_service/certificate.go:473) falls back to
# reading exactly those per-domain files, every synced certificate also shows up in
# the Domain SSL panel -- so no one is left staring at an empty box.
#
# ADDING A NEW DOMAIN
# -------------------
# The certificate must be issued by the proxy, because the proxy owns port 80:
#   1. add the domain in BillionMail (for its DNS/DKIM records)
#   2. add its hostname to a Dokploy app with "Let's Encrypt" enabled, so Traefik
#      issues a certificate for it
#   3. this sidecar picks it up on its next pass and installs it
# BillionMail's own "Apply Free Certificate" remains non-functional behind a proxy.
#
# RENEWAL
# -------
# The proxy renews ~30 days before expiry and this runs every few minutes, so the
# installed certificate always has far more than the 3 days BillionMail's own
# AutoRenewSSL waits for. It therefore never fires and never logs failed challenges.
# Renewal is fully automatic.
#
# If no acme.json is mounted (a deployment with no reverse proxy, where nothing
# steals port 80) this is a harmless no-op and BillionMail's own ACME works normally.
#
set -eu

ACME_FILE="${ACME_FILE:-/acme/acme.json}"
CERT_RESOLVER="${CERT_RESOLVER:-letsencrypt}"
CERT_DOMAIN="${CERT_DOMAIN:-}"
SSL_DIR="${SSL_DIR:-/ssl}"
INTERVAL="${INTERVAL:-300}"

# Portable across GNU date and busybox (the sidecar runs on Alpine).
log() { echo "[certsync] $(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }

# Environment values are compared EXACTLY against strings inside acme.json, so a
# stray CR (CRLF .env), a trailing space or a trailing dot makes the comparison
# fail while every log line still looks perfectly correct. Normalise defensively
# and name the offending variable.
#
# Sets NORM_OUT and may log -- never call it inside a command substitution, or the
# warning lines would be captured into the variable.
NORM_OUT=""
norm() {
    name="$1"; raw="$2"; def="$3"
    [ -n "$raw" ] || raw="$def"
    val=$(printf '%s' "$raw" | tr -d '\r' \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/\.*$//')
    if [ "$raw" != "$val" ]; then
        log "WARNING: $name was not clean; using [$val]"
        log "         raw bytes:$({ printf '%s' "$raw" | od -An -c | tr -s ' '; })"
        log "         fix it where it is defined (Dokploy environment or .env)"
    fi
    NORM_OUT="$val"
}

norm ACME_FILE     "${ACME_FILE:-}"     /acme/acme.json; ACME_FILE="$NORM_OUT"
norm CERT_RESOLVER "${CERT_RESOLVER:-}" letsencrypt;     CERT_RESOLVER="$NORM_OUT"
norm CERT_DOMAIN   "${CERT_DOMAIN:-}"   "";              CERT_DOMAIN="$NORM_OUT"
norm SSL_DIR       "${SSL_DIR:-}"       /ssl;            SSL_DIR="$NORM_OUT"
norm INTERVAL      "${INTERVAL:-}"      300;             INTERVAL="$NORM_OUT"

if [ -z "$CERT_DOMAIN" ]; then
    log "CERT_DOMAIN is empty (set BILLIONMAIL_HOSTNAME); nothing to do"
    exit 0
fi

# jq is required to read acme.json safely; install it once if the image lacks it.
if ! command -v jq >/dev/null 2>&1; then
    log "installing jq"
    apk add --no-cache jq >/dev/null 2>&1 || { log "FATAL: could not install jq"; exit 1; }
fi

# Print every certificate's primary domain under the configured resolver.
cert_domains() {
    jq -r --arg r "$CERT_RESOLVER" '.[$r].Certificates[]? | .domain.main // empty' \
        "$ACME_FILE" 2>/dev/null | sort -u
}

# Traefik stores the certificate and key as Go []byte, and encoding/json renders
# []byte as BASE64 -- not PEM. Everything downstream (postfix, dovecot, BillionMail)
# needs PEM, so decode here. A value that is already PEM is passed through
# unchanged, so either storage form works.
decode_pem() {
    v="$1"
    case "$v" in
        *"BEGIN "*) printf '%s\n' "$v"; return 0 ;;
    esac
    out=$(printf '%s' "$v" | base64 -d 2>/dev/null) \
        || out=$(printf '%s' "$v" | openssl base64 -d -A 2>/dev/null) \
        || { log "could not decode PEM material from acme.json (not base64 or PEM)"; return 1; }
    printf '%s\n' "$out"
}

# Print one PEM field of the certificate whose primary domain (or SAN) is $1.
#
# The field name is matched case-INSENSITIVELY over the object's own keys: Traefik
# writes this struct with inconsistent JSON tags (domain and certificate key are
# lower case, but "Store" is capitalised), and relying on one exact spelling
# silently yields null -- which then looks like "no certificate present".
#
# jq's stderr is deliberately NOT suppressed: if the file cannot be read or parsed,
# the reason must reach the container log instead of a bare "not found".
extract_field() {
    want="$1"; field="$2"
    jq -r --arg r "$CERT_RESOLVER" --arg d "$want" --arg f "$field" '
        [ .[$r].Certificates[]?
          | select((.domain.main == $d) or (((.domain.sans // []) | index($d)) != null)) ]
        | if length == 0 then empty
          else ( [ .[0] | to_entries[] | select((.key | ascii_downcase) == $f) | .value ] | first )
          end
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
    log "certificate object keys: $(jq -r --arg r "$CERT_RESOLVER" '.[$r].Certificates[0]? | keys | join(",")' "$ACME_FILE" 2>/dev/null)"

    domains=$(cert_domains)
    if [ -z "$domains" ]; then
        log "no certificates under resolver '$CERT_RESOLVER' in $ACME_FILE"
        log "certificates present: $(jq -r 'to_entries[] | .key as $r | (.value.Certificates // [])[] | "\($r)=\(.domain.main)"' "$ACME_FILE" 2>/dev/null | tr '\n' ' ')"
        return 0
    fi

    tmp=$(mktemp -d)
    CHANGED=0
    synced=""

    for d in $domains; do
        # Domains become path components, so refuse anything that is not a hostname.
        case "$d" in
            ""|*/*|*..*|*[!A-Za-z0-9.-]*)
                log "skipping unexpected domain name from acme.json: [$d]"
                continue
                ;;
        esac

        c=$(extract_field "$d" certificate)
        k=$(extract_field "$d" key)
        [ -n "$c" ] && c=$(decode_pem "$c") || c=""
        [ -n "$k" ] && k=$(decode_pem "$k") || k=""

        case "$c" in *"BEGIN CERTIFICATE"*) ;; *) log "no usable certificate for [$d]"; continue ;; esac
        case "$k" in *"PRIVATE KEY"*)       ;; *) log "no usable private key for [$d]"; continue ;; esac

        printf '%s\n' "$c" > "$tmp/cert.pem"
        printf '%s\n' "$k" > "$tmp/key.pem"

        install_if_changed "$tmp/cert.pem" "$SSL_DIR/$d/fullchain.pem"
        install_if_changed "$tmp/key.pem"  "$SSL_DIR/$d/privkey.pem"

        # The mail daemons read these two fixed names, so they follow the primary
        # mail hostname only.
        if [ "$d" = "$CERT_DOMAIN" ]; then
            install_if_changed "$tmp/cert.pem" "$SSL_DIR/cert.pem"
            install_if_changed "$tmp/key.pem"  "$SSL_DIR/key.pem"
        fi

        synced="$synced $d"
    done
    rm -rf "$tmp"

    if [ -z "$synced" ]; then
        log "no certificates could be installed"
        return 0
    fi

    if [ "$CHANGED" = 1 ]; then
        log "installed certificates for:$synced"
        reload_services
    else
        log "certificates already current for:$synced"
    fi
}

# Brackets make hidden characters (e.g. a stray CR) visible.
log "start: primary=[$CERT_DOMAIN] resolver=[$CERT_RESOLVER] acme=$ACME_FILE interval=${INTERVAL}s"
while :; do
    sync_once || log "sync attempt failed (will retry)"
    sleep "$INTERVAL"
done
