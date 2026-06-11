#!/usr/bin/env bash
# =============================================================================
# ONROL — one-command cloud bootstrap.
#
# Stands up the WHOLE stack on a fresh Ubuntu/Debian server:
#   PostgreSQL  +  Go API (Fiber)  +  Flutter web app  +  nginx  (+ optional TLS)
#
# Anyone with git can run it. Two ways:
#
#   A) On a fresh server, straight from GitHub:
#        curl -fsSL https://raw.githubusercontent.com/glydi/onrol-infra/main/scripts/cloud_bootstrap.sh \
#          | sudo bash
#
#   B) From a clone:
#        git clone https://github.com/glydi/onrol-infra.git
#        sudo bash onrol-infra/scripts/cloud_bootstrap.sh
#
# Options (all optional — sensible defaults):
#   DOMAIN=app.example.com   # public hostname. Default: <public-ip>.sslip.io (no DNS needed)
#   EMAIL=you@example.com    # for Let's Encrypt. If set + real domain -> HTTPS is provisioned
#   REPO_URL=...             # git repo to build (default: this project's origin)
#   BRANCH=main              # branch to build
#   ADMIN_EMAIL / ADMIN_PASSWORD   # seed a first admin account after boot
#
# Re-running is safe (idempotent): it updates the build and restarts services.
# =============================================================================
set -euo pipefail

# ---- Settings ---------------------------------------------------------------
REPO_URL="${REPO_URL:-https://github.com/glydi/onrol-infra.git}"
BRANCH="${BRANCH:-main}"
SRC_DIR="${SRC_DIR:-/opt/onrol-src}"
APP_DIR="/opt/onrol"          # runtime: binary + .env
WEB_ROOT="/var/www/onrol"     # nginx static root (Flutter web build)
GO_VERSION="${GO_VERSION:-1.25.0}"
FLUTTER_REF="${FLUTTER_REF:-stable}"
FLUTTER_DIR="${FLUTTER_DIR:-/opt/flutter}"
GOROOT="/usr/local/go"

log()  { printf '\n\033[1;36m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root (use sudo)."
command -v apt-get >/dev/null || die "this script targets Debian/Ubuntu (apt-get not found)."
ARCH="$(dpkg --print-architecture)"   # amd64 | arm64
case "$ARCH" in amd64|arm64) ;; *) die "unsupported arch: $ARCH" ;; esac

# ---- Public IP + domain -----------------------------------------------------
PUBLIC_IP="$(curl -fsS https://api.ipify.org 2>/dev/null || curl -fsS https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"
[ -n "$PUBLIC_IP" ] || die "could not determine public IP; pass DOMAIN=... explicitly."
DOMAIN="${DOMAIN:-${PUBLIC_IP//./-}.sslip.io}"
CRM_DOMAIN="crm.${DOMAIN}"
EMAIL="${EMAIL:-}"

log "Bootstrapping ONROL"
echo "    repo     : $REPO_URL ($BRANCH)"
echo "    public IP: $PUBLIC_IP"
echo "    domain   : $DOMAIN  (+ $CRM_DOMAIN)"
echo "    arch     : $ARCH"

# ---- 1. System packages -----------------------------------------------------
log "[1/8] Installing system packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git curl ca-certificates unzip xz-utils rsync openssl \
    postgresql nginx certbot python3-certbot-nginx \
    build-essential pkg-config >/dev/null
systemctl enable --now postgresql >/dev/null 2>&1 || true

# ---- 2. Go toolchain --------------------------------------------------------
log "[2/8] Installing Go $GO_VERSION"
if ! "$GOROOT/bin/go" version 2>/dev/null | grep -q "go$GO_VERSION"; then
  curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${ARCH}.tar.gz" -o /tmp/go.tgz
  rm -rf "$GOROOT"
  tar -C /usr/local -xzf /tmp/go.tgz
  rm -f /tmp/go.tgz
fi
export PATH="$GOROOT/bin:$PATH"
go version

# ---- 3. Flutter SDK ---------------------------------------------------------
log "[3/8] Installing Flutter ($FLUTTER_REF)"
if [ ! -x "$FLUTTER_DIR/bin/flutter" ]; then
  git clone --depth 1 -b "$FLUTTER_REF" https://github.com/flutter/flutter.git "$FLUTTER_DIR"
fi
export PATH="$FLUTTER_DIR/bin:$PATH"
git config --global --add safe.directory "$FLUTTER_DIR" || true
flutter --version || die "flutter install failed"
flutter config --enable-web >/dev/null
flutter precache --web >/dev/null

# ---- 4. Source checkout -----------------------------------------------------
log "[4/8] Fetching source"
# If this script lives inside a checkout, build that; else clone fresh.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-/nonexistent}")" 2>/dev/null && pwd || true)"
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/../backend/go.mod" ]; then
  SRC_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
  echo "    using local checkout: $SRC_DIR"
elif [ -d "$SRC_DIR/.git" ]; then
  git -C "$SRC_DIR" fetch --depth 1 origin "$BRANCH"
  git -C "$SRC_DIR" checkout -f "$BRANCH"
  git -C "$SRC_DIR" reset --hard "origin/$BRANCH"
else
  rm -rf "$SRC_DIR"
  git clone --depth 1 -b "$BRANCH" "$REPO_URL" "$SRC_DIR"
fi
git config --global --add safe.directory "$SRC_DIR" || true

# ---- 5. Database + .env -----------------------------------------------------
log "[5/8] Provisioning database + config"
id onrol >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin onrol
install -d -m 750 "$APP_DIR"
if [ ! -f "$APP_DIR/.env" ]; then
  DBPASS="$(openssl rand -hex 24)"
  sudo -u postgres psql -tAc "DO \$\$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='onrol') THEN CREATE ROLE onrol LOGIN PASSWORD '$DBPASS'; ELSE ALTER ROLE onrol PASSWORD '$DBPASS'; END IF; END \$\$;"
  sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='onrol'" | grep -q 1 \
    || sudo -u postgres createdb -O onrol onrol
  cat > "$APP_DIR/.env" <<ENV
APP_ENV=production
PORT=8080
DATABASE_URL=postgres://onrol:${DBPASS}@127.0.0.1:5432/onrol?sslmode=disable
JWT_SECRET=$(openssl rand -hex 32)
JWT_ACCESS_TTL=24h
MAX_DEVICES_PER_USER=2
ATTESTATION_MODE=log
ADMIN_API_KEY=$(openssl rand -hex 16)
ZOHO_WEBINAR_BASE=https://webinar.zoho.in
ENV
  echo "    wrote $APP_DIR/.env (new DB credentials generated)"
else
  echo "    $APP_DIR/.env exists — keeping it"
fi
chmod 600 "$APP_DIR/.env"

# ---- 5b. Swap safeguard (Flutter web compile needs ~2GB) --------------------
RAM_MB="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"
if [ "${RAM_MB:-0}" -lt 2048 ] && [ ! -f /swapfile ]; then
  log "Low RAM (${RAM_MB}MB) — adding a 2G swapfile so the web build won't OOM"
  fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048
  chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# ---- 6. Build backend + web -------------------------------------------------
log "[6/8] Building API (Go) and web app (Flutter)"
( cd "$SRC_DIR/backend" && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o "$APP_DIR/onrol-server" ./cmd/server )
echo "    built API binary"

( cd "$SRC_DIR/app" && flutter pub get >/dev/null && flutter build web --release --no-tree-shake-icons --pwa-strategy=none >/dev/null )
install -d "$WEB_ROOT"
rsync -a --delete "$SRC_DIR/app/build/web/" "$WEB_ROOT/"
echo "    built + published web app"
chown -R onrol:onrol "$APP_DIR"

# ---- 7. systemd + nginx -----------------------------------------------------
log "[7/8] Installing systemd unit + nginx site"
install -m 644 "$SRC_DIR/deploy/onrol.service" /etc/systemd/system/onrol.service
systemctl daemon-reload
systemctl enable --now onrol.service
systemctl restart onrol.service

# nginx site: serve the web app, proxy /api + /healthz to the Go server.
# Two server_names: the main domain and crm.<domain> (the CRM portal).
write_http_site() {
  cat > /etc/nginx/sites-available/onrol <<NGINX
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN} ${CRM_DOMAIN};

    root ${WEB_ROOT};
    index index.html;
    client_max_body_size 25m;

    location /api/      { proxy_pass http://127.0.0.1:8080; proxy_set_header Host \$host; proxy_set_header X-Real-IP \$remote_addr; proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto \$scheme; }
    location = /healthz { proxy_pass http://127.0.0.1:8080; }
    location /          { try_files \$uri \$uri/ /index.html; }
}
NGINX
}
write_http_site
ln -sf /etc/nginx/sites-available/onrol /etc/nginx/sites-enabled/onrol
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

# ---- 8. TLS (optional) ------------------------------------------------------
log "[8/8] TLS"
if [ -n "$EMAIL" ]; then
  echo "    requesting Let's Encrypt certs for ${DOMAIN} + ${CRM_DOMAIN}"
  certbot --nginx --non-interactive --agree-tos -m "$EMAIL" --redirect \
      -d "$DOMAIN" -d "$CRM_DOMAIN" || warn "certbot failed — staying on HTTP (check DNS points to $PUBLIC_IP)."
else
  warn "EMAIL not set — skipping HTTPS. Serving over HTTP."
  warn "To enable TLS later: certbot --nginx -d $DOMAIN -d $CRM_DOMAIN -m you@example.com --agree-tos"
fi

# ---- Optional: seed first admin --------------------------------------------
if [ -n "${ADMIN_EMAIL:-}" ] && [ -n "${ADMIN_PASSWORD:-}" ]; then
  log "Seeding admin account ${ADMIN_EMAIL}"
  # Register via the app's own endpoint, then elevate the role to superadmin.
  curl -fsS -X POST "http://127.0.0.1:8080/api/v1/auth/register" \
      -H 'Content-Type: application/json' \
      -H 'X-Device-UUID: bootstrap' \
      -d "{\"email\":\"${ADMIN_EMAIL}\",\"password\":\"${ADMIN_PASSWORD}\",\"full_name\":\"Admin\"}" >/dev/null 2>&1 || true
  if sudo -u postgres psql onrol -c "UPDATE users SET role='superadmin' WHERE lower(email)=lower('${ADMIN_EMAIL}');" >/dev/null 2>&1; then
    echo "    admin ready: ${ADMIN_EMAIL}"
  else
    warn "could not seed admin (register may be disabled)."
  fi
fi

# ---- Health check + summary -------------------------------------------------
sleep 2
HEALTH="$(curl -fsS http://127.0.0.1:8080/healthz || echo 'DOWN')"
SCHEME="http"; [ -n "$EMAIL" ] && SCHEME="https"
printf '\n\033[1;32m✓ ONROL is up.\033[0m\n'
printf '    API health : %s\n' "$HEALTH"
printf '    LMS / app  : %s://%s\n' "$SCHEME" "$DOMAIN"
printf '    CRM portal : %s://%s\n' "$SCHEME" "$CRM_DOMAIN"
printf '    Service    : systemctl status onrol     (logs: journalctl -u onrol -f)\n'
printf '    Re-deploy  : re-run this script (pulls latest + rebuilds)\n\n'
