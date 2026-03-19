export GITHUB_USER="${1:-${GITHUB_USER:-}}"
export GITHUB_TOKEN="${2:-${GITHUB_TOKEN:-}}"
export AZURE_TENANT_ID="${3:-${AZURE_TENANT_ID:-}}"
export AZURE_SEARCH_APP_ID="${4:-${AZURE_SEARCH_APP_ID:-}}"

if [ -z "$GITHUB_USER" ] || [ -z "$GITHUB_TOKEN" ]; then
  echo "Usage: ./run.sh <github-user> <github-token> <azure-tenant-id> <azure-search-app-id>"
  echo "   or: GITHUB_USER=x GITHUB_TOKEN=y AZURE_TENANT_ID=z AZURE_SEARCH_APP_ID=w ./run.sh"
  exit 1
fi

if [ -z "$AZURE_TENANT_ID" ] || [ -z "$AZURE_SEARCH_APP_ID" ]; then
  echo "Error: AZURE_TENANT_ID and AZURE_SEARCH_APP_ID must be set"
  exit 1
fi

# ── Auth ──────────────────────────────────────────────────────────────────────
#echo "$GITHUB_TOKEN" | docker login ghcr.io -u "$GITHUB_USER" --password-stdin

# ── Shared network (allows MFE nginx to proxy to backend by container name) ───
docker network create srs-net 2>/dev/null || true

# ── search-report-service (backend) ──────────────────────────────────────────
docker stop search-report-service 2>/dev/null; docker rm search-report-service 2>/dev/null

docker run -d --pull always \
  --name search-report-service \
  --network srs-net \
  -p 3215:8080 \
  -v /tmp/search-report-db:/data/db \
  -v /Users/marekb/workspace/spfo/fo-configuration-ch:/data/config \
  -e DB_PATH="/data/db" \
  -e CONFIGURATION_BASE_PATH="/data/config/" \
#  -e JAVA_TOOL_OPTIONS="-Dhttp.proxyHost=127.0.0.1 -Dhttp.proxyPort=8800" \
  -e SPRING_PROFILES_ACTIVE="prod" \
  -e IDENTITY_PROVIDER="azure" \
  -e APP_LOGGING_LEVEL="debug" \
  -e DOSSIER_MOCK_ENABLED="true" \
  -e OPENID_ISSUER_URI="https://login.microsoftonline.com/${AZURE_TENANT_ID}/v2.0" \
  -e OPENID_CLIENT_ID="AZURE_CLIENT_ID" \
  -e OPENID_CLIENT_SECRET="AZURE_CLIENT_SECRET" \
  -e OPENID_REDIRECT_URI="https://YOUR_DOMAIN/search-report-service/" \
  -e OPENID_SEARCH_SCOPE="api://${AZURE_SEARCH_APP_ID}/search" \
  -e SEARCH_REPORT_SERVICE_CONTEXT_PATH="/search-report-service" \
  -e SEARCH_REPORT_SERVICE_PORT="8080" \
  ghcr.io/marekballa/search-report-service:develop

docker stop search-report-mfe 2>/dev/null; docker rm search-report-mfe 2>/dev/null

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$SCRIPT_DIR/nginx-templates"
cat > "$SCRIPT_DIR/nginx-templates/default.conf.template" << 'EOF'
server {
  listen 8080;

  gzip on;
  gzip_disable "msie6";
  gzip_vary on;
  gzip_proxied any;
  gzip_comp_level 6;
  gzip_buffers 16 8k;
  gzip_http_version 1.1;
  gzip_min_length 0;
  gzip_types text/plain application/javascript text/css application/json application/x-javascript text/xml application/xml application/xml+rss text/javascript application/vnd.ms-fontobject application/x-font-ttf font/opentype;

  # Proxy API calls to the search-report-service backend container
  location /search-report-service/ {
    proxy_pass http://search-report-service:8080/search-report-service/;
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

docker run -d --pull always \
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
  ghcr.io/marekballa/search-report-service-mfe:develop

# ── Access points ─────────────────────────────────────────────────────────────
echo ""
echo "  Frontend:  http://localhost:8080/srs"
echo "  Backend:   http://localhost:3215/search-report-service  (direct, for debugging)"
echo ""

docker logs -f search-report-mfe &
docker logs -f search-report-service
