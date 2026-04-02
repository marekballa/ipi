#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# run-podman.sh — Build and run search-report-service + MFE locally from source
#
# Prerequisites (must be installed on host):
#   git       — clone/update repos
#   docker    — build images and run containers (aliased as podman if needed)
#
# Required environment variables:
#   IPI_TOKEN     — GitLab oauth2 token for git.epo.org (used for git clones
#                   and as GIT_TOKEN build arg inside Dockerfile.prod)
#
# Optional environment variables:
#   PROXY_HOST    — HTTP proxy host (e.g. 127.0.0.1)
#   PROXY_PORT    — HTTP proxy port (e.g. 8800)
#   PNPM_CACHE    — set to "true" to enable BuildKit pnpm store cache mount
#                   for faster repeated dtk-mfe builds (default: false)
#
# Usage:
#   ./run-podman.sh               — full build: sync repos, build images, start containers
#   ./run-podman.sh restart       — skip sync + build, just restart containers from existing images
#   ./run-podman.sh stop          — stop both containers
#   PROXY_HOST=127.0.0.1 PROXY_PORT=8800 ./run-podman.sh
#   PNPM_CACHE=true ./run-podman.sh
#
# What it does:
#   1. Clones or fast-forward pulls: search-report-service, fo-configuration-ch, dtk-mfe
#   2. Builds search-report-service:local  via Dockerfile.prod  (Maven build inside Docker)
#   3. Builds search-report-mfe:local      via dtk-mfe/Dockerfile (pnpm build inside Docker)
#   4. Starts search-report-service on :3215  (backend, mocked dossiers)
#   5. Starts search-report-mfe on :8080      (nginx: serves MFE + proxies /search-report-service/)
#
# Access points after startup:
#   Frontend : http://localhost:8080/srs (dtk mfe)
#   Backend  : http://localhost:8080/search-report-service  (main entry point)
#              http://localhost:3215/search-report-service  (direct, for debugging)
# ──────────────────────────────────────────────────────────────────────────────
set -e

MODE="${1:-build}"  # build | restart | stop

# Optional proxy: PROXY_HOST=host PROXY_PORT=port ./run-podman.sh
export PROXY_HOST="${PROXY_HOST:-}"
export PROXY_PORT="${PROXY_PORT:-}"

# Use docker if podman is not installed
if ! command -v podman &>/dev/null; then
  podman() { docker "$@"; }
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPOS_DIR="$SCRIPT_DIR"

if [ "$MODE" = "stop" ]; then
  echo "Stopping containers..."
  podman stop search-report-service 2>/dev/null || true
  podman stop search-report-mfe 2>/dev/null || true
  exit 0
fi

if [ "$MODE" = "restart" ]; then
  echo "Restart mode — skipping sync and build, restarting containers from existing images."
else
  if [ -z "$IPI_TOKEN" ]; then
    echo "Error: IPI_TOKEN must be set (export IPI_TOKEN=<your-token>)"
    exit 1
  fi

  # Used as GIT_PASSWORD inside the dtk-mfe Docker build for cloning from git.epo.org
  export GITLAB_TOKEN="${IPI_TOKEN}"

  # ── Proxy args (optional) ───────────────────────────────────────────────────
  GIT_PROXY_ARGS=""
  DOCKER_PROXY_ARGS=""
  if [ -n "$PROXY_HOST" ] && [ -n "$PROXY_PORT" ]; then
    GIT_PROXY_ARGS="-c http.proxy=http://${PROXY_HOST}:${PROXY_PORT} -c https.proxy=http://${PROXY_HOST}:${PROXY_PORT}"
    # Docker predefined proxy args — auto-applied to all RUN commands (git, wget, apk, npm, pnpm)
    # PROXY_HOST/PORT also passed for Maven inside Dockerfile.prod
    DOCKER_PROXY_ARGS="--build-arg HTTP_PROXY=http://${PROXY_HOST}:${PROXY_PORT} --build-arg HTTPS_PROXY=http://${PROXY_HOST}:${PROXY_PORT} --build-arg PROXY_HOST=${PROXY_HOST} --build-arg PROXY_PORT=${PROXY_PORT}"
  fi

  # ── Clone or pull a repo ─────────────────────────────────────────────────────
  # Usage: sync_repo <dir> <repo-url>
  sync_repo() {
    local dir="$1"
    local url="$2"
    # Embed token for GitLab oauth2 auth
    local auth_url
    auth_url=$(echo "$url" | sed "s|https://|https://oauth2:${IPI_TOKEN}@|")

    if [ ! -d "$dir/.git" ]; then
      echo "Cloning $(basename "$dir")..."
      git $GIT_PROXY_ARGS clone "$auth_url" "$dir"
    else
      echo "Updating $(basename "$dir")..."
      git -C "$dir" $GIT_PROXY_ARGS fetch origin
      # Only reset if there are no local (uncommitted) changes
      if git -C "$dir" diff --quiet && git -C "$dir" diff --cached --quiet; then
        git -C "$dir" reset --hard origin/$(git -C "$dir" rev-parse --abbrev-ref HEAD)
      else
        echo "  → local changes detected in $(basename "$dir"), skipping reset"
      fi
    fi
  }

  # ── Sync repos ──────────────────────────────────────────────────────────────
  sync_repo "$REPOS_DIR/search-report-service"   "https://git.epo.org/it-cooperation/search-report-service.git"
  sync_repo "$REPOS_DIR/fo-configuration-ch"    "https://git.epo.org/it-cooperation/fo-configuration-ch.git"
  sync_repo "$REPOS_DIR/dtk-mfe"                "https://git.epo.org/it-cooperation/dtk-mfe.git"

  # ── Build search-report-service Docker image (Dockerfile.prod builds JAR internally) ──
  # Dockerfile.prod expects a config/ dir and .build-libs/ (proprietary JARs) in the build context
  mkdir -p "$REPOS_DIR/search-report-service/config"
  mkdir -p "$REPOS_DIR/search-report-service/.build-libs"
  cp "$SCRIPT_DIR/iaik_jce-signed-4.0.jar" "$REPOS_DIR/search-report-service/.build-libs/"

  echo "Building search-report-service image..."
  podman build --no-cache \
    -f "$REPOS_DIR/search-report-service/Dockerfile.prod" \
    --build-arg GIT_TOKEN="${IPI_TOKEN}" \
    $DOCKER_PROXY_ARGS \
    -t search-report-service:local \
    "$REPOS_DIR/search-report-service"

  echo "Done — image: search-report-service:local"

  # ── Build dtk-mfe image ─────────────────────────────────────────────────────
  # Optional: PNPM_CACHE=true ./run-podman.sh — patches the Dockerfile locally to
  # add a BuildKit cache mount for the pnpm store, speeding up repeated builds.
  DTK_DOCKERFILE="$REPOS_DIR/dtk-mfe/Dockerfile"
  if [ "${PNPM_CACHE:-false}" = "true" ]; then
    echo "Using pnpm BuildKit cache mount..."
    sed 's|RUN pnpm run docker:init|RUN --mount=type=cache,target=/root/.local/share/pnpm/store pnpm run docker:init|' \
      "$DTK_DOCKERFILE" > "$SCRIPT_DIR/.Dockerfile.dtk-mfe-local"
    DTK_DOCKERFILE="$SCRIPT_DIR/.Dockerfile.dtk-mfe-local"
  fi

  echo "Building dtk-mfe image..."
  podman build \
    -f "$DTK_DOCKERFILE" \
    --build-arg DTK_REPO_REF=develop \
    --build-arg DTK_FE_COMMON_REF=develop \
    --build-arg GIT_USERNAME=oauth2 \
    --build-arg GIT_PASSWORD="${GITLAB_TOKEN}" \
    $DOCKER_PROXY_ARGS \
    -t search-report-mfe:local \
    "$REPOS_DIR/dtk-mfe"

  rm -f "$SCRIPT_DIR/.Dockerfile.dtk-mfe-local"
fi  # end build mode

# ── Shared network (allows MFE nginx to proxy to backend by container name) ───
podman network create srs-net 2>/dev/null || true

# ── search-report-service (backend) ──────────────────────────────────────────
podman stop search-report-service 2>/dev/null || true; podman rm search-report-service 2>/dev/null || true

podman run -d \
  --name search-report-service \
  --network srs-net \
  -p 3215:8080 \
  -v "$REPOS_DIR/fo-configuration-ch:/data/config" \
  -e DB_PATH="/data/db" \
  -e CONFIGURATION_BASE_PATH="/data/config/" \
  -e SPRING_PROFILES_ACTIVE="prod" \
  -e IDENTITY_PROVIDER="azure" \
  -e APP_LOGGING_LEVEL="debug" \
  -e DOSSIER_MOCK_ENABLED="true" \
  -e OPENID_ISSUER_URI="https://login.microsoftonline.com/b16225bd-49b8-4999-b571-c19a911ae1ec/v2.0" \
  -e OPENID_CLIENT_ID="AZURE_CLIENT_ID" \
  -e OPENID_CLIENT_SECRET="AZURE_CLIENT_SECRET" \
  -e OPENID_REDIRECT_URI="https://YOUR_DOMAIN/search-report-service/" \
  -e OPENID_SEARCH_SCOPE="api://a87b6d3d-d85e-4d9b-8704-6aed76a49444/search" \
  -e SEARCH_REPORT_SERVICE_CONTEXT_PATH="/search-report-service" \
  -e SEARCH_REPORT_SERVICE_PORT="8080" \
  search-report-service:local

# ── search-report-mfe (frontend) ─────────────────────────────────────────────
podman stop search-report-mfe 2>/dev/null || true; podman rm search-report-mfe 2>/dev/null || true

# Docker user-defined networks use 127.0.0.11 as the embedded DNS resolver,
# allowing nginx to resolve container names (e.g. search-report-service) at request time.
mkdir -p "$SCRIPT_DIR/nginx-templates"
cat > "$SCRIPT_DIR/nginx-templates/default.conf.template" << 'EOF'
server {
  listen 8080;

  gzip on;
  gzip_vary on;
  gzip_proxied any;
  gzip_comp_level 6;
  gzip_buffers 16 8k;
  gzip_http_version 1.1;
  gzip_min_length 0;
  gzip_types text/plain application/javascript text/css application/json application/x-javascript text/xml application/xml application/xml+rss text/javascript application/vnd.ms-fontobject application/x-font-ttf font/opentype;

  resolver 127.0.0.11 valid=10s;

  location /search-report-service/ {
    set $upstream search-report-service;
    proxy_pass http://$upstream:8080;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_read_timeout 60s;
  }

  location /srs {
    add_header Set-Cookie environment=${ENVIRONMENT};
    rewrite /srs/(.*) /$1 break;
    root /usr/share/nginx/html;
    index index.html index.htm;
    try_files $uri $uri/ /index.html;
    add_header X-Frame-Options DENY;
  }

  location / {
    add_header Set-Cookie environment=${ENVIRONMENT};
    rewrite /(.*) /$1 break;
    root /usr/share/nginx/html;
    index index.html index.htm;
    try_files $uri $uri/ /index.html;
    add_header X-Frame-Options DENY;
  }

  location /stub_status {
    stub_status;
    allow 127.0.0.1;
    deny all;
  }
}
EOF

podman run -d \
  --name search-report-mfe \
  --network srs-net \
  -p 8080:8080 \
  -v "$SCRIPT_DIR/nginx-templates:/etc/nginx/templates" \
  -e DTK_BASE_PATH="/srs" \
  -e DTK_SHELL_ID="back-office" \
  -e DTK_CONFIGURATION_SERVICE_URL="/search-report-service" \
  -e DTK_SEARCH_REPORT_SERVICE_URL="/search-report-service" \
  -e DTK_USER_SERVICE_URL="/search-report-service" \
  -e DTK_KEYCLOAK_REALM="" \
  -e DTK_KEYCLOAK_CLIENT="" \
  -e ENVIRONMENT="develop" \
  search-report-mfe:local

# ── Access points ─────────────────────────────────────────────────────────────
echo ""
echo "  Frontend:  http://localhost:8080/srs"
echo "  Backend:   http://localhost:3215/search-report-service  (direct, for debugging)"
echo ""

podman logs -f search-report-mfe &
podman logs -f search-report-service

# Cleanup
rm -f "$SCRIPT_DIR/nginx-templates/default.conf.template"
rmdir "$SCRIPT_DIR/nginx-templates" 2>/dev/null || true