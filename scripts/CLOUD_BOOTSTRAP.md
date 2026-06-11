# One-command cloud deploy

`scripts/cloud_bootstrap.sh` builds and runs the **entire stack** on a fresh
Ubuntu/Debian server — PostgreSQL + Go API + Flutter web app + nginx (+ optional
HTTPS). Anyone with git and a cloud VM can run it.

## Quick start

On a fresh server (Ubuntu 22.04/24.04 or Debian 12, amd64 or arm64):

```bash
# Straight from GitHub — no clone needed:
curl -fsSL https://raw.githubusercontent.com/glydi/onrol-infra/main/scripts/cloud_bootstrap.sh | sudo bash
```

or from a clone:

```bash
git clone https://github.com/glydi/onrol-infra.git
sudo bash onrol-infra/scripts/cloud_bootstrap.sh
```

That's it. With no options it serves over **HTTP** on a free
`<your-ip>.sslip.io` hostname (no DNS setup required) and prints the URLs.

## With your own domain + HTTPS

Point an `A` record for `yourdomain.com` **and** `crm.yourdomain.com` at the
server's IP, then:

```bash
sudo DOMAIN=yourdomain.com EMAIL=you@yourdomain.com \
  bash onrol-infra/scripts/cloud_bootstrap.sh
```

Let's Encrypt certs are issued for both the app and the CRM portal automatically.

## Seed a first admin (optional)

```bash
sudo ADMIN_EMAIL=admin@you.com ADMIN_PASSWORD='change-me-123' \
  bash onrol-infra/scripts/cloud_bootstrap.sh
```

## All options (env vars)

| Var | Default | Purpose |
|-----|---------|---------|
| `DOMAIN` | `<public-ip>.sslip.io` | Public hostname for the app |
| `EMAIL` | _(unset)_ | Let's Encrypt email — set it to enable HTTPS |
| `REPO_URL` | this project's origin | Git repo to build |
| `BRANCH` | `main` | Branch to build |
| `ADMIN_EMAIL` / `ADMIN_PASSWORD` | _(unset)_ | Seed a superadmin account |
| `GO_VERSION` | `1.25.0` | Go toolchain version |
| `FLUTTER_REF` | `stable` | Flutter channel/tag |

## What it does

1. Installs system packages (Postgres, nginx, certbot, build tools).
2. Installs the Go toolchain and the Flutter SDK.
3. Adds a 2 GB swapfile if RAM < 2 GB (the web compile needs it).
4. Clones/updates the source.
5. Creates the `onrol` Postgres role + DB and writes `/opt/onrol/.env`
   (random DB password + JWT secret). DB migrations auto-apply on first boot.
6. Builds the Go API → `/opt/onrol/onrol-server` and the Flutter web app →
   `/var/www/onrol`.
7. Installs the `onrol` systemd service and an nginx site that serves the web
   app and proxies `/api` + `/healthz` to the API. Adds a `crm.<domain>` vhost
   for the CRM portal.
8. Provisions TLS if `EMAIL` is set.

## Day-2

- **Re-deploy latest:** re-run the script — it pulls `main`, rebuilds, restarts.
- **Logs:** `journalctl -u onrol -f`
- **Status:** `systemctl status onrol`
- **Config:** `/opt/onrol/.env` (DB URL, JWT secret, device limit, etc.)

> Idempotent: existing `.env` and DB are preserved across re-runs.
