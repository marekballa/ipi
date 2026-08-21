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
  #   PROXY_USER    — proxy username (optional, if proxy requires auth)
  #   PROXY_PASS    — proxy password (optional, if proxy requires auth)
  #   PNPM_CACHE    — set to "true" to enable BuildKit pnpm store cache mount
  #                   for faster repeated dtk-mfe builds (default: false)
  #
  # Usage:
  #   ./run-podman.sh               — full build: sync repos, build images, start containers
  #   ./run-podman.sh restart       — skip sync + build, just restart containers from existing images
  #   ./run-podman.sh stop          — stop both containers
  #   PROXY_HOST=127.0.0.1 PROXY_PORT=8800 ./run-podman.sh
  #   is
  #
  # What it does:
  #   1. Clones or fast-forward pulls: search-report-service, fo-configuration-ch, dtk-mfe
  #   2. Builds search-report-service:local  via Dockerfile.prod  (Maven build inside Docker)
  #   3. Builds search-report-mfe:local      via dtk-mfe/Dockerfile (pnpm build inside Docker)
  #   4. Starts search-report-service on :3215  (backend, mocked dossiers)
  #   5. Starts search-report-mfe on :8080      (nginx: serves MFE + proxies /search-report-service/)
  #
  # Access points after startup:
  #   Frontend : http://localhost:8000/srs (dtk mfe)
  #   Backend  : http://localhost:8000/search-report-service  (main entry point)
  #              http://localhost:3215/search-report-service  (direct, for debugging)
  # ──────────────────────────────────────────────────────────────────────────────
  set -e

  MODE="${1:-build}"  # build | restart | stop

  # Optional TLS: CERT_PATH=/path/to/dir (must contain server.crt and server.key)
  export CERT_PATH="${CERT_PATH:-}"

  # Optional proxy: PROXY_HOST=host PROXY_PORT=port [PROXY_USER=u PROXY_PASS=p] ./run-podman.sh
  export PROXY_HOST="${PROXY_HOST:-}"
  export PROXY_PORT="${PROXY_PORT:-}"
  export PROXY_USER="${PROXY_USER:-}"
  export PROXY_PASS="${PROXY_PASS:-}"
  if [ -n "$PROXY_HOST" ] && [ -n "$PROXY_PORT" ]; then
    echo "Proxy configured: http://${PROXY_HOST}:${PROXY_PORT}"
  else
    echo "Proxy: not configured (PROXY_HOST=${PROXY_HOST:-<empty>} PROXY_PORT=${PROXY_PORT:-<empty>})"
  fi

  # Version tag to checkout for release builds
  COMMIT_REF="${2:-"${VERSION:-"develop"}"}"

  DEP_REF_ARGS="--build-arg DEP_REF=${COMMIT_REF}"
  echo "[info] DEP_REF_ARGS used for podman build: ${DEP_REF_ARGS}"

  # Image names
  IMAGE_REF_SRS="${IMAGE_REF_SRS:-"epo/search-report-service:${COMMIT_REF}"}"
  IMAGE_REF_SRM="${IMAGE_REF_SRM:-"epo/search-report-mfe:${COMMIT_REF}"}"

  # OpenID credentials — when both are provided, real Azure auth is used and mock is disabled
  export OPENID_CLIENT_ID="${OPENID_CLIENT_ID:-}"
  export OPENID_CLIENT_SECRET="${OPENID_CLIENT_SECRET:-}"
  export OPENID_REDIRECT_URI="${OPENID_REDIRECT_URI:-https://YOUR_DOMAIN/search-report-service/api/oauth/callback}"
  export AUTHENTICATED_SEARCH_ENDPOINT="${AUTHENTICATED_SEARCH_ENDPOINT:-https://search.epo.org/search-service-layer/master/v4/api/transit}"
  if [ -n "$OPENID_CLIENT_ID" ] && [ -n "$OPENID_CLIENT_SECRET" ]; then
    DOSSIER_MOCK_ENABLED="false"
    echo "OpenID credentials provided — mock disabled, real auth enabled"
  else
    DOSSIER_MOCK_ENABLED="true"
    echo "OpenID credentials not set — running in mock mode (DOSSIER_MOCK_ENABLED=true)"
  fi

  # Use docker if podman is not installed
  if ! command -v podman &>/dev/null; then
    podman() { docker "$@"; }
  fi

  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  REPOS_DIR="$SCRIPT_DIR"

  # ── System diagnostics ────────────────────────────────────────────────────────
  echo "=== System ==="
  uname -a || true
  echo ""

  echo "=== Container runtime ==="
  if command -v podman &>/dev/null; then
    echo "podman: $(podman --version)"
  else
    echo "podman: not found, using docker"
    docker --version || true
  fi
  echo ""

  echo "=== Proxy environment ==="
  echo "  PROXY_HOST=${PROXY_HOST:-(not set)}"
  echo "  PROXY_PORT=${PROXY_PORT:-(not set)}"
  for var in HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy; do
    val="${!var:-}"
    if [ -n "$val" ]; then
      echo "  $var=$val"
    else
      echo "  $var=(not set)"
    fi
  done
  echo ""

  echo "=== Network connectivity ==="
  if command -v curl &>/dev/null; then
    curl -s -o /dev/null -w "  docker.io:      HTTP %{http_code} (via %{local_ip})\n" --max-time 5 https://registry-1.docker.io/v2/ || echo "  docker.io:      unreachable"
    curl -s -o /dev/null -w "  git.epo.org:    HTTP %{http_code}\n" --max-time 5 https://git.epo.org || echo "  git.epo.org:    unreachable"
    curl -s -o /dev/null -w "  dl-cdn.alpinelinux.org: HTTP %{http_code}\n" --max-time 5 https://dl-cdn.alpinelinux.org || echo "  dl-cdn.alpinelinux.org: unreachable"
  elif command -v wget &>/dev/null; then
    wget -q --spider --timeout=5 https://registry-1.docker.io/v2/ 2>&1 | head -1 || true
    wget -q --spider --timeout=5 https://git.epo.org 2>&1 | head -1 || true
  else
    echo "  (curl and wget not available — skipping)"
  fi
  echo ""
  echo "============================================"
  echo ""

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
    if [ -z "$IPI_GITHUB_TOKEN" ]; then
      echo "Error: IPI_GITHUB_TOKEN must be set (export IPI_GITHUB_TOKEN=<your-token>)"
      exit 1
    fi

    # Used as GIT_PASSWORD inside the dtk-mfe Docker build for cloning from git.epo.org
    export GITLAB_TOKEN="${IPI_TOKEN}"

    # ── Proxy args (optional) ───────────────────────────────────────────────────
    GIT_PROXY_ARGS=""
    DOCKER_PROXY_ARGS=""
    if [ -n "$PROXY_HOST" ] && [ -n "$PROXY_PORT" ]; then
      # Build proxy URL with optional credentials: http://[user:pass@]host:port
      if [ -n "$PROXY_USER" ] && [ -n "$PROXY_PASS" ]; then
        PROXY_URL="http://${PROXY_USER}:${PROXY_PASS}@${PROXY_HOST}:${PROXY_PORT}"
      else
        PROXY_URL="http://${PROXY_HOST}:${PROXY_PORT}"
      fi
      GIT_PROXY_ARGS="-c http.proxy=${PROXY_URL} -c https.proxy=${PROXY_URL} -c http.sslVerify=false"
      # Docker predefined proxy args — auto-applied to all RUN commands (git, wget, apk, npm, pnpm)
      # PROXY_HOST/PORT also passed for Maven inside Dockerfile.prod
      DOCKER_PROXY_ARGS="--build-arg HTTP_PROXY=${PROXY_URL} --build-arg HTTPS_PROXY=${PROXY_URL} --build-arg PROXY_HOST=${PROXY_HOST} --build-arg PROXY_PORT=${PROXY_PORT}"
      echo "Proxy: ${PROXY_URL}"
    else
      echo "Proxy: none (set PROXY_HOST and PROXY_PORT to enable)"
    fi

    # ── Clone or pull a repo ─────────────────────────────────────────────────────
    # Usage: sync_repo <dir> <repo-url>
    sync_repo() {
      local dir="$1"
      local url="$2"
      local branch="${3:-"default"}"
      # Embed token for GitHub token auth (username can be anything, token is the password)
      local auth_url
      auth_url=$(echo "$url" | sed "s|https://|https://${IPI_GITHUB_TOKEN}@|")

      if [ ! -d "$dir/.git" ]; then
        echo "Cloning $(basename "$dir")..."
        git $GIT_PROXY_ARGS clone "$auth_url" "$dir"
        if [[ -d "$dir" && "$branch" != "default" ]]; then
          (cd "$dir" && git checkout "$branch")
        fi
      else
        echo "Updating $(basename "$dir")..."
        if ! git -C "$dir" $GIT_PROXY_ARGS fetch origin; then
          echo "  → fetch failed, re-cloning $(basename "$dir")..."
          rm -rf "$dir"
          git $GIT_PROXY_ARGS clone "$auth_url" "$dir"
          if [[ -d "$dir" && "$branch" != "default" ]]; then
            (cd "$dir" && git checkout "$branch")
          fi
        else
          # Only reset if there are no local (uncommitted) changes
          if git -C "$dir" diff --quiet && git -C "$dir" diff --cached --quiet; then
            git -C "$dir" reset --hard origin/$(git -C "$dir" rev-parse --abbrev-ref HEAD)
          else
            echo "  → local changes detected in $(basename "$dir"), skipping reset"
          fi
        fi
      fi
    }

    # ── Sync repos ──────────────────────────────────────────────────────────────
    GITHUB_BASE_URL="https://github.com/epo-it-cooperation"
    sync_repo "$REPOS_DIR/search-report-service" "${GITHUB_BASE_URL}/search-report-service.git" "${COMMIT_REF}"
    sync_repo "$REPOS_DIR/fo-configuration-ch"   "${GITHUB_BASE_URL}/fo-configuration-ch.git"   "${COMMIT_REF}"
    sync_repo "$REPOS_DIR/dtk-mfe"               "${GITHUB_BASE_URL}/dtk-mfe.git"               "${COMMIT_REF}"

    # Patch importmap.json to serve MFE bundles from local nginx instead of GCS
    IMPORTMAP="$REPOS_DIR/fo-configuration-ch/apps/back-office/-shell/importmap.json"
    if [ -f "$IMPORTMAP" ]; then
      sed -i.bak 's|https://storage.googleapis.com/[^"]*develop/|{{basePath}}/artifacts/|g' "$IMPORTMAP"
      rm -f "$IMPORTMAP.bak"
      echo "Patched importmap.json"
    else
      echo "WARNING: importmap.json not found at $IMPORTMAP — skipping patch"
    fi

    # ── Build search-report-service Docker image (Dockerfile.prod builds JAR internally) ──
    mkdir -p "$REPOS_DIR/search-report-service/config"

    # ADDED: bake patched fo-configuration-ch into the image so no runtime volume mount is needed
    rm -rf "$REPOS_DIR/search-report-service/config"
    cp -r "$REPOS_DIR/fo-configuration-ch" "$REPOS_DIR/search-report-service/config"

    echo "Building search-report-service image..."
    podman build --no-cache \
      -f "$REPOS_DIR/search-report-service/Dockerfile.prod" \
      --build-arg GIT_TOKEN="${IPI_GITHUB_TOKEN}" \
      $DEP_REF_ARGS \
      $DOCKER_PROXY_ARGS \
      -t "${IMAGE_REF_SRS}" \
      "$REPOS_DIR/search-report-service"

    echo "Done — image: ${IMAGE_REF_SRS}"

    # ── Build dtk-mfe image ─────────────────────────────────────────────────────
    # Patch dtk-mfe/Dockerfile locally for corporate SSL inspection environments:
    #   - apk: switch Alpine repos to HTTP (corporate proxy replaces HTTPS certs, CA not trusted in container)
    #   - npm: disable strict-ssl before installing pnpm
    #   - pnpm/Node: NODE_TLS_REJECT_UNAUTHORIZED=0 for all pnpm installs inside docker:init
    # Also optionally add pnpm BuildKit cache mount (PNPM_CACHE=true).
    DTK_DOCKERFILE="$REPOS_DIR/dtk-mfe/Dockerfile"
    cp "$DTK_DOCKERFILE" "$SCRIPT_DIR/.Dockerfile.dtk-mfe-local"
    DTK_DOCKERFILE="$SCRIPT_DIR/.Dockerfile.dtk-mfe-local"

    # Patch the Dockerfile via awk — avoids macOS BSD sed misinterpreting '|' inside
    # replacement strings as delimiters, which causes "bad flag in substitute command: 'h'".
    # awk is a POSIX standard tool available on all macOS/Linux hosts without installation.
    awk '{
      if ($0 == "RUN apk add --no-cache git")
        print "RUN sed -i \"s|https://|http://|g\" /etc/apk/repositories && apk add --no-cache git"
      else if ($0 ~ /^RUN npm install -g pnpm/)
        print "RUN npm config set strict-ssl false && " substr($0, 5)
      else
        print
      if ($0 ~ /^ENV NODE_ENV=/) {
        print "ENV NODE_TLS_REJECT_UNAUTHORIZED=0"
        print "ENV GIT_SSL_NO_VERIFY=true"
      }
      # ADDED: overwrite the nginx template that docker:init produced with our CH version
      if ($0 ~ /^RUN pnpm run docker:init/) {
        print "RUN cp /usr/src/app/nginx-ch-override.template /usr/src/app/docker-build/nginx/default_prd.dtk.conf.template"
      }
    }' "$DTK_DOCKERFILE" > "${DTK_DOCKERFILE}.tmp" && mv "${DTK_DOCKERFILE}.tmp" "$DTK_DOCKERFILE"

    if [ "${PNPM_CACHE:-false}" = "true" ]; then
      echo "Using pnpm BuildKit cache mount..."
      awk '{
        gsub(/RUN pnpm run docker:init/, "RUN --mount=type=cache,target=/root/.local/share/pnpm/store pnpm run docker:init")
        print
      }' "$DTK_DOCKERFILE" > "${DTK_DOCKERFILE}.tmp" && mv "${DTK_DOCKERFILE}.tmp" "$DTK_DOCKERFILE"
    fi

    # ADDED: bake CH nginx template with /search-report-service/ proxy into the image so no runtime nginx mount is needed
    # Written to the root of the build context (dtk-mfe/); the Dockerfile's `COPY . .`
    # brings it to /usr/src/app/, then the awk-injected `RUN cp ...` overrides the
    # template that docker:init produced.
    cat > "$REPOS_DIR/dtk-mfe/nginx-ch-override.template" <<'NGINX_EOF'
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

  location /search-report-service/ {
    proxy_pass ${SEARCH_REPORT_SERVICE_UPSTREAM}/search-report-service/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $http_x_forwarded_proto;
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
NGINX_EOF

    echo "=== Patched dtk-mfe Dockerfile ==="
    cat "$DTK_DOCKERFILE"
    echo "=================================="
    echo ""

    echo "Building dtk-mfe image..."
    podman build \
      -f "$DTK_DOCKERFILE" \
      --build-arg DTK_REPO_REF=${COMMIT_REF} \
      --build-arg DTK_FE_COMMON_REF=${COMMIT_REF} \
      --build-arg GIT_USERNAME=oauth2 \
      --build-arg GIT_PASSWORD="${GITLAB_TOKEN}" \
      $DEP_REF_ARGS \
      $DOCKER_PROXY_ARGS \
      -t "${IMAGE_REF_SRM}" \
      "$REPOS_DIR/dtk-mfe"

    echo "Done — image: ${IMAGE_REF_SRM}"

    rm -f "$SCRIPT_DIR/.Dockerfile.dtk-mfe-local"
  fi  # end build mode


  # In build mode stop after build, do not restart
  if [ "$MODE" = "build" ]; then
    echo "end of build"
    exit 0
  fi

