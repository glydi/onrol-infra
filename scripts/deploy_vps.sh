#!/usr/bin/env bash
# Native (Docker-less) deploy to an Ubuntu VPS: cross-compile the Go binary
# locally, ship it, and run it under systemd behind the system nginx. Designed
# for small boxes (1 vCPU) where a Docker stack is overkill.
#
#   HOST=root@187.127.178.100 DOMAIN=187-127-178-100.sslip.io scripts/deploy_vps.sh
#
# Assumes: SSH key access to HOST, and a Let's Encrypt cert already present at
# /etc/letsencrypt/live/$DOMAIN (we reused an existing sslip.io cert).
set -euo pipefail

HOST="${HOST:?set HOST=root@<ip>}"
DOMAIN="${DOMAIN:?set DOMAIN=<your.domain>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "[1/5] cross-compiling linux/amd64 binary"
( cd "$ROOT/backend" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -trimpath -ldflags="-s -w" -o /tmp/onrol-server-linux ./cmd/server )

echo "[2/5] shipping binary"
ssh "$HOST" 'install -d -m 750 /opt/onrol'
scp /tmp/onrol-server-linux "$HOST:/opt/onrol/onrol-server.new"

echo "[3/5] provisioning DB + .env (idempotent; only writes .env if absent)"
ssh "$HOST" "DOMAIN=$DOMAIN bash -s" <<'REMOTE'
set -e
command -v psql >/dev/null || { export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq postgresql; }
systemctl enable --now postgresql
id onrol >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin onrol
if [ ! -f /opt/onrol/.env ]; then
  DBPASS=$(openssl rand -hex 24)
  sudo -u postgres psql -tAc "DO \$\$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='onrol') THEN CREATE ROLE onrol LOGIN PASSWORD '$DBPASS'; ELSE ALTER ROLE onrol PASSWORD '$DBPASS'; END IF; END \$\$;"
  sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='onrol'" | grep -q 1 || sudo -u postgres createdb -O onrol onrol
  cat > /opt/onrol/.env <<ENV
APP_ENV=production
PORT=8080
DATABASE_URL=postgres://onrol:$DBPASS@127.0.0.1:5432/onrol?sslmode=disable
JWT_SECRET=$(openssl rand -hex 32)
JWT_ACCESS_TTL=24h
MAX_DEVICES_PER_USER=2
ATTESTATION_MODE=log
ADMIN_API_KEY=$(openssl rand -hex 16)
ZOHO_WEBINAR_BASE=https://webinar.zoho.in
ENV
fi
chmod 600 /opt/onrol/.env
REMOTE

echo "[4/5] installing systemd unit + nginx site"
scp "$ROOT/deploy/onrol.service" "$HOST:/etc/systemd/system/onrol.service"
sed "s/DOMAIN/$DOMAIN/g" "$ROOT/deploy/nginx-onrol.conf" | ssh "$HOST" "cat > /etc/nginx/sites-available/onrol"
ssh "$HOST" "DOMAIN=$DOMAIN bash -s" <<'REMOTE'
set -e
# Atomic-ish binary swap, then restart.
mv /opt/onrol/onrol-server.new /opt/onrol/onrol-server
chmod +x /opt/onrol/onrol-server
chown -R onrol:onrol /opt/onrol
systemctl daemon-reload
systemctl enable --now onrol.service
systemctl restart onrol.service
ln -sf /etc/nginx/sites-available/onrol /etc/nginx/sites-enabled/onrol
nginx -t && systemctl reload nginx
# Nightly backups.
install -d -m 750 -o onrol -g onrol /opt/onrol/backups
cat > /opt/onrol/backup.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
OUT=/opt/onrol/backups/onrol-$(date +%Y%m%d-%H%M%S).sql.gz
sudo -u postgres pg_dump onrol | gzip > "$OUT"
find /opt/onrol/backups -name 'onrol-*.sql.gz' -mtime +14 -delete
SH
chmod +x /opt/onrol/backup.sh
echo '30 2 * * * root /opt/onrol/backup.sh >> /var/log/onrol-backup.log 2>&1' > /etc/cron.d/onrol-backup
REMOTE

echo "[5/5] health check"
sleep 2
curl -fsS "https://$DOMAIN/healthz" && echo " <- deployed OK"
