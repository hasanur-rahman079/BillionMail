# Deploying this fork (Dokploy / Traefik)

This fork carries two deliberate changes on top of upstream `dev`. Everything else
tracks upstream and can be merged normally.

1. **All persistent state uses named volumes** (`docker-compose.yml`).
2. **`certsync-billionmail`** keeps the mail TLS certificate in sync with the proxy.

## 1. Named volumes — why

Upstream mounts state with *relative* bind mounts (`./postgresql-data`, `./vmail-data`,
`./ssl`, `./rspamd-data`, …). Those resolve **inside the git checkout**. Dokploy
regenerates that checkout on deploy, so every one of those directories is recreated
empty. Postgres then finds an empty `PGDATA`, runs `initdb`, and silently builds a
fresh cluster — destroying domains, contacts, campaigns, and the DKIM/cert material.

This fork replaces them with named volumes, which live in `/var/lib/docker/volumes`,
outside the checkout:

| Volume | Container path | Holds |
|---|---|---|
| `bm-postgresql-data` | `/var/lib/postgresql/data` | the database |
| `bm-vmail-data` | `/var/vmail` | mailbox mail |
| `bm-rspamd-data` | `/var/lib/rspamd` | DKIM private keys, bayes |
| `bm-ssl` | `/etc/ssl/mail` | mail TLS certificates |
| `bm-postfix-data` | `/var/spool/postfix` | mail queue |
| `bm-webmail-data`, `bm-core-data`, `bm-redis-data`, `bm-postgresql-socket` | — | supporting state |

`conf/`, `logs/`, `ssl-self-signed/`, `php-sock/` and `.env` remain bind mounts on
purpose: `conf/` holds tracked configuration (an empty volume would shadow it), and
the rest are disposable or regenerated at container start.

**Consequence:** never edit those paths on the server — the checkout is replaced on
every deploy. Change them in this repo instead.

## 2. Certificates — why `certsync` exists

BillionMail issues its own certificates with a hardcoded **HTTP-01** challenge
(`core/internal/service/domains/ssl.go` → `ApplySSLWithExistingServer(..., "http", ...)`).

Behind Dokploy that can never work. Traefik owns port 80 and installs a **global**
handler for `/.well-known/acme-challenge/` on the `web` entrypoint. It answers that
path for every host it manages, returns 404 for tokens it does not recognise, and
**does not fall through to any router**. The tell-tale log line is:

```
ERR Cannot retrieve the ACME challenge for mail.example.com (token "...")
```

No router, priority or middleware change can fix this — port 80 cannot be shared.
So instead of competing, this fork lets the proxy own issuance **and** renewal, and
copies the result into the mail services:

```
Traefik acme.json ──▶ certsync-billionmail ──▶ bm-ssl (cert.pem / key.pem)
                                                   │
                                       postfix + dovecot read these directly
```

`postfix` reads `/etc/ssl/mail/cert.pem` + `key.pem` (`conf/postfix/main.cf`), and
`dovecot` reads the same two files (`conf/dovecot/conf.d/10-ssl.conf`). `certsync`
writes those and reloads both services when the content changes.

Because the proxy renews ~30 days before expiry and `certsync` copies it within the
hour, the installed certificate always has well over 3 days left — so BillionMail's
own `AutoRenewSSL` (which fires at <3 days, `ssl.go`) never triggers and never logs
failed challenge attempts. **Renewal is fully automatic.**

**In the UI, ignore "Apply Free Certificate".** It will always fail with a 404 while
Traefik's certresolver is active. The Domain SSL dialog will show no certificate
because the cert comes from the proxy — that display is cosmetic; mail TLS is what
matters and it is handled.

If you deploy somewhere with **no** reverse proxy, nothing steals port 80, `acme.json`
is absent, and `certsync` is a harmless no-op — BillionMail's own ACME works normally.

## Required environment

`.env` must define at least:

```
TZ=UTC
DBNAME=billionmail
DBUSER=billionmail
DBPASS=<secret>
REDISPASS=<secret>
BILLIONMAIL_HOSTNAME=mail.example.com   # also the certificate domain
ADMIN_USERNAME=<set by core.sh if absent>
ADMIN_PASSWORD=<set by core.sh if absent>
HTTP_PORT=8080
HTTPS_PORT=8443
```

Optional, for `certsync`:

```
CERT_RESOLVER=letsencrypt               # must match the proxy's certresolver name
ACME_DIR=/etc/dokploy/traefik/dynamic   # where acme.json lives
ACME_FILE=/acme/acme.json
CERTSYNC_INTERVAL=3600
```

The proxy must already be configured to issue a certificate for
`BILLIONMAIL_HOSTNAME`, and that hostname must resolve directly to this server with
**no proxy/CDN in front** (Cloudflare "DNS only", grey cloud) — otherwise the
challenge never reaches the origin.

Verify at any time:

```bash
for p in 465 993; do
  openssl s_client -connect mail.example.com:$p -servername mail.example.com </dev/null 2>/dev/null \
    | openssl x509 -noout -subject -issuer -dates
done
```

## DKIM

DKIM private keys live **only** as files (`bm-rspamd-data/dkim/<domain>/<selector>.private`).
They are not in the database and not in any database backup. If that volume is ever
lost, BillionMail regenerates the keys — and the **DKIM TXT record at your DNS
provider must be updated to match**, or outgoing mail will fail DKIM. This is a
manual step; there is no way around it when keys are regenerated.

## Backups

A database dump is **not** a full backup. It covers `bm-postgresql-data` only. It does
not cover:

- `bm-vmail-data` — actual mailbox contents
- `bm-rspamd-data` — DKIM private keys
- `bm-ssl` — certificates
- `.env` — credentials

Back up the volumes as well as the database, and keep a retention window. Verify
restores occasionally; an untested backup is not a backup.

## Recovering after a data loss

```bash
P=<project>-pgsql-billionmail-1

docker exec -i $P sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"' <<'SQL'
select count(*) as domains from domain;
select count(*) as mailboxes from mailbox;
select count(*) as contacts from bm_contacts;
select count(*) as certs from letsencrypts;
SQL
```

Restore the newest dump through Dokploy's Restore dialog using database user
`billionmail`. If it fails on existing relations, reset and retry:

```bash
docker exec -i $P sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"'
```

Schema migration is automatic: core runs `CREATE TABLE IF NOT EXISTS` plus the
idempotent `AddColumnIfNotExists` on every startup, so an older dump is migrated
forward safely.

## Known upstream issues seen in logs

- `Failed to cleanup duplicates or create unique index: SELECT "1" FROM "pg_indexes"…`
  — `core/internal/service/database_initialization/smtp_relay.go:104` uses
  `Fields("1")`, which renders as `SELECT "1"`; in Postgres double quotes mean an
  *identifier*, so this always errors. The effect is that the `uk_relay_domain` index
  is never created and the relay domain-mapping cleanup aborts on every startup.
- `fail2ban ERROR Could not find server` — cosmetic.
