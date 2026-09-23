# Deploying this fork (Dokploy / Traefik)

This fork carries deliberate changes on top of upstream `dev`. Everything else tracks
upstream and can be merged normally.

1. **All persistent state uses named volumes** (`docker-compose.yml`).
2. **`certsync-billionmail`** keeps TLS certificates in sync with the proxy.

Throughout, `<project>` is the Dokploy project name — the prefix on every container and
volume (e.g. `emspub-billionmail-v3wo9m`). `mail.example.com` stands for
`BILLIONMAIL_HOSTNAME`.

## 1. Named volumes — why

Upstream mounts state with *relative* bind mounts (`./postgresql-data`, `./vmail-data`,
`./ssl`, `./rspamd-data`, …). Those resolve **inside the git checkout**. Dokploy
regenerates that checkout on deploy, so every one of those directories is recreated
empty. Postgres then finds an empty `PGDATA`, runs `initdb`, and silently builds a fresh
cluster — destroying domains, contacts, campaigns and the DKIM/cert material.

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
purpose: `conf/` holds tracked configuration (an empty volume would shadow it), and the
rest are disposable or regenerated at container start.

**Consequence:** never edit those paths on the server — the checkout is replaced on every
deploy. Change them in this repo instead.

### Still relative: `conf/postfix/sql`

One runtime path is still inside the checkout. `postfix.sh` regenerates the six
`pgsql_*.cf` lookup maps there **at container start**, so they come back whenever the
postfix container is recreated. If postfix logs

```
warning: open "pgsql" configuration "/etc/postfix/sql/pgsql_virtual_domains_maps.cf": No such file or directory
```

then the container has not restarted since the checkout was replaced. Create the
directory and restart it:

```bash
cd /etc/dokploy/compose/<project>/code
mkdir -p conf/postfix/sql
docker restart <project>-postfix-billionmail-1
```

Two further warnings for `pgsql_sender_relay_maps.cf` / `pgsql_sender_transport_maps.cf`
are expected unless the SMTP-relay feature has been configured — those maps are created
by BillionMail when relay config is saved, and their absence is harmless.

Verify the maps actually resolve against the database:

```bash
docker exec <project>-postfix-billionmail-1 \
  postmap -q ems.pub pgsql:/etc/postfix/sql/pgsql_virtual_domains_maps.cf
# should echo the domain back
```

## 2. Certificates — why `certsync` exists

BillionMail issues its own certificates with a hardcoded **HTTP-01** challenge
(`core/internal/service/domains/ssl.go` → `ApplySSLWithExistingServer(..., "http", ...)`).

Behind Dokploy that can never work. Traefik owns port 80 and installs a **global**
handler for `/.well-known/acme-challenge/` on the `web` entrypoint. It answers that path
for every host it manages, returns 404 for tokens it does not recognise, and **does not
fall through to any router**. The tell-tale log line is:

```
ERR Cannot retrieve the ACME challenge for mail.example.com (token "...")
```

No router, priority or middleware change can fix this — port 80 cannot be shared. So
instead of competing, this fork lets the proxy own issuance **and** renewal, and copies
the results into the mail services:

```
Traefik acme.json ──▶ certsync-billionmail ──▶ bm-ssl
                                                 ├─ cert.pem / key.pem          (primary hostname)
                                                 └─ <domain>/fullchain.pem
                                                    <domain>/privkey.pem        (every domain)
                                                        │
                                        postfix + dovecot read cert.pem / key.pem
```

`postfix` reads `/etc/ssl/mail/cert.pem` + `key.pem` (`conf/postfix/main.cf`) and
`dovecot` the same two files (`conf/dovecot/conf.d/10-ssl.conf`). Those two fixed names
always follow the **primary** hostname (`BILLIONMAIL_HOSTNAME`).

### Implementation notes worth knowing

- **The PEM values in `acme.json` are base64, not PEM.** Traefik stores the certificate
  and key as Go `[]byte`, and `encoding/json` renders `[]byte` as base64. `certsync`
  decodes it, and passes through a value that is already PEM.
- **`certsync` syncs every certificate in `acme.json`,** not just one domain, so a newly
  added domain is picked up automatically.
- **It restarts postfix and dovecot rather than reloading them.** A reload is not
  dependable for TLS material: `doveadm reload` reported success while dovecot kept
  serving the previous certificate, because the daemon caches the parsed certificate in
  memory. Restarts only happen when the certificate content actually changes (~twice a
  year), and the queue and mailboxes live on volumes, so nothing is lost.
- **The UI shows these certificates.** `getSSLInfo`
  (`core/internal/service/mail_service/certificate.go:473`) falls back to reading
  `/etc/ssl/mail/<domain>/fullchain.pem` + `privkey.pem` — exactly what `certsync`
  writes — so the Domain SSL column and dialog display the live certificate and its
  remaining days.
- **`CERTSYNC_VERSION` must be bumped whenever `scripts/certsync.sh` changes.** The
  script is a bind-mounted *file*, and Compose only recreates a container when its
  configuration changes; without a version bump a deploy silently keeps running the
  previous script from a replaced inode. This has already bitten once.

### Renewal timeline

Nothing to do, ever:

```
Traefik renews ~30 days before expiry  →  writes acme.json
certsync runs every CERTSYNC_INTERVAL   →  (default 300s) copies it to bm-ssl
   └─ content changed → restart postfix + dovecot → new cert served
```

When the content is unchanged — almost every pass — `certsync` writes nothing and
restarts nothing. Because the installed certificate always carries 30+ days of validity,
BillionMail's own `AutoRenewSSL` (which fires under **3 days**, `ssl.go:406`) never
triggers, so there are no failed challenge attempts and no Let's Encrypt rate-limit risk.

**Failure mode to watch:** if the proxy's renewal fails, the certificate quietly stops
advancing and `certsync` cannot tell you. Watch the Traefik log for `Error renewing ACME
certificate`, or check the remaining days in the Domain SSL panel.

**In the UI, ignore "Apply Free Certificate".** It will always fail with a 404 while
Traefik's certresolver is active, for every domain. The SSL column is the real indicator.

If you deploy somewhere with **no** reverse proxy, nothing steals port 80, `acme.json` is
absent, and `certsync` is a harmless no-op — BillionMail's own ACME works normally.

## 3. Adding a domain

Two different jobs, and they need different things. **Decide which you want first.**

### A. Sending only (no HTTPS site on that domain)

This is the common case, and it needs **nothing in Dokploy**.

1. **BillionMail → Domain → Add Domain.** Creates the domain and generates its DKIM pair
   (stored in `bm-rspamd-data`, which survives redeploys).
2. **Publish the records from the DNS Records button** on that domain's row:

   | Record | Name | Value | Purpose |
   |---|---|---|---|
   | A | `mail.newdomain.com` | this server's public IP | SPF `a`/`mx`, and receiving |
   | TXT (SPF) | `newdomain.com` | `v=spf1 +a +mx -all` | authorises this server |
   | TXT (DKIM) | `<selector>._domainkey.newdomain.com` | generated public key | signs outgoing mail |
   | TXT (DMARC) | `_dmarc.newdomain.com` | `v=DMARC1; p=none; …` | policy + reporting |
   | MX | `newdomain.com` | `10 mail.newdomain.com` | only if you want to receive |

   Use the exact values the UI shows. The `mail.newdomain.com` A record is safe to
   publish: that hostname is not in Dokploy, so Traefik has no router for it and nothing
   serves the panel there. Only ports 25/587/993 answer.
3. **Settings → General → Reverse Proxy Domain → `https://mail.example.com`.** This is
   what makes a send-only domain's missing certificate irrelevant: without it BillionMail
   builds tracking, click and unsubscribe links from the sending domain and falls back to
   the internal container address (upstream's docs warn about links leaking `:5679`). With
   it set, every domain's links resolve to the hostname that *does* have a valid
   certificate.
4. Send from any address on that domain. Create a mailbox only if you also want to
   receive replies there.
5. **Verify authentication**, not just delivery. Send to a Gmail address and read the
   headers:

   ```
   Authentication-Results: mx.google.com;
      spf=pass ... dkim=pass ... dmarc=pass
   ```

   `dkim=pass` is the one that fails when the TXT record does not match the generated key
   — worth re-checking after any key regeneration.

The SSL column stays empty for a send-only domain. That is cosmetic; ignore it.

### B. Serving HTTPS on that domain

Needed only for BillionMail tracking/landing pages or webmail on its own hostname. The
certificate **must** come from Traefik, so:

1. **Publish the DNS record first** and confirm it, because Let's Encrypt rate-limits
   failed validations to **5 per hour per hostname**:

   ```bash
   dig +short A newdomain.com @1.1.1.1     # must be this server, with NO proxy/CDN
   ```

2. **Dokploy → the BillionMail app → Domains tab → Add Domain.** Mirror the values from
   the existing `mail.example.com` entry (open it and copy them — that entry is proven
   working):

   | Field | Value |
   |---|---|
   | Host | `newdomain.com` |
   | Path | `/` |
   | Service Name | `core-billionmail` |
   | Container Port | `8080` |
   | HTTPS | on |
   | Certificate Provider | `letsencrypt` (must match the resolver name) |

   Only `core-billionmail` serves HTTP; the postfix/dovecot/rspamd/pgsql/webmail/certsync
   services are irrelevant to Traefik.

3. **Nothing else.** Traefik completes the challenge, stores the certificate, and
   `certsync` installs it within 5 minutes. Verify:

   ```bash
   docker logs --since 10m dokploy-traefik 2>&1 | grep -iE "acme|certificate" | tail
   jq -r '.letsencrypt.Certificates[].domain.main' /etc/dokploy/traefik/dynamic/acme.json | grep newdomain
   docker logs --tail 12 <project>-certsync-billionmail-1
   ```

**Note:** the DNS record must be *direct*. A CDN or proxy in front (Cloudflare orange
cloud, Hostinger proxy) answers port 80 itself, so the challenge never reaches Traefik
and validation fails. BillionMail's own UI says the same thing: *"If using CloudFlare,
please select [DNS only] when adding records."*

## Required environment

`.env` must define at least:

```
TZ=UTC
DBNAME=billionmail
DBUSER=billionmail
DBPASS=<secret>
REDISPASS=<secret>
BILLIONMAIL_HOSTNAME=mail.example.com   # also the primary certificate domain
ADMIN_USERNAME=<set by core.sh if absent>
ADMIN_PASSWORD=<set by core.sh if absent>
HTTP_PORT=8080
HTTPS_PORT=8443
```

Optional, for `certsync`:

```
CERT_RESOLVER=letsencrypt               # must match the proxy's certresolver name
ACME_DIR=/etc/dokploy/traefik/dynamic   # directory holding acme.json
ACME_FILE=/acme/acme.json
CERTSYNC_INTERVAL=300                   # seconds between passes
CERTSYNC_VERSION=5                      # bump with every scripts/certsync.sh change
```

`BILLIONMAIL_HOSTNAME` is also passed to postfix and dovecot as their hostname, so a
dirty value (trailing space, CR from a CRLF `.env`) also yields a malformed
`myhostname`. `certsync` normalises its own inputs and warns by name, but fix the source.

## Verify TLS

```bash
H=mail.example.com
for p in 465 993; do                     # implicit TLS
  printf -- "--- %s: " "$p"
  openssl s_client -connect $H:$p -servername $H </dev/null 2>/dev/null | openssl x509 -noout -issuer -enddate
done
openssl s_client -connect $H:587 -starttls smtp -servername $H </dev/null 2>/dev/null \
  | openssl x509 -noout -issuer -enddate   # 587 is STARTTLS, not implicit TLS
```

Expect `issuer=… Let's Encrypt …`. A bare `s_client` against 587 always fails to read a
certificate — that is expected, not a fault.

## DKIM

DKIM private keys live **only** as files (`bm-rspamd-data/dkim/<domain>/<selector>.private`).
They are not in the database and not in any database backup. If that volume is lost,
BillionMail regenerates the keys — and the **DKIM TXT record at your DNS provider must be
updated to match**, or outgoing mail fails DKIM. This step cannot be automated without
DNS API credentials.

## Backups

A database dump is **not** a full backup. It covers `bm-postgresql-data` only. It does not
cover:

- `bm-vmail-data` — actual mailbox contents
- `bm-rspamd-data` — DKIM private keys
- `bm-ssl` — certificates
- `.env` — credentials

Enable a **schedule with retention**, and **Volume Backups** for the volumes above — now
possible because state moved out of the checkout. Verify restores occasionally: an
untested backup is not a backup.

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

Schema migration is automatic: core runs `CREATE TABLE IF NOT EXISTS` plus the idempotent
`AddColumnIfNotExists` on every startup, so an older dump is migrated forward safely.

## Operational rules

- **Never run `docker compose` inside the checkout.** `docker-compose.yml` declares
  `name: billionmail`, while Dokploy runs the project as `<project>`. Running compose
  there starts a *second* stack with new volumes. Use Dokploy's Deploy button, or
  `docker restart <container>`.
- **Never edit files in the checkout** (`/etc/dokploy/compose/<project>/code`). It is
  replaced on every deploy. Change the repo instead.
- **Bump `CERTSYNC_VERSION` with any `scripts/certsync.sh` change**, or the deploy will
  not pick it up.
- **Verify after deploying a change:** the timestamp in `docker logs <project>-certsync-billionmail-1`
  must be recent, and its first line prints the resolved domain, resolver and settings.

## Known upstream issues seen in logs

- `Failed to cleanup duplicates or create unique index: SELECT "1" FROM "pg_indexes"…`
  — `core/internal/service/database_initialization/smtp_relay.go:104` uses `Fields("1")`,
  which renders as `SELECT "1"`; in Postgres double quotes mean an *identifier*, so this
  always errors. The `uk_relay_domain` index is therefore never created and the relay
  domain-mapping cleanup aborts on every startup.
- `fail2ban ERROR Could not find server` — cosmetic.
- `postconf: warning: open "pgsql" configuration … pgsql_sender_relay_maps.cf` — expected
  until the SMTP-relay feature is configured (see "Still relative" above).
