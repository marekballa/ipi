# Search Report Service — IPI Deployment

## Quick start (automated)

```bash
chmod +x run-podman.sh

# build the images (default command, you could omit the 'build' parameter)
IPI_TOKEN=<your-gitlab-token> ./run-podman.sh build

# run or restart the images
./run-podman.sh restart

# stop the images
./run-podman.sh stop
```

This builds both images and starts all containers. See the script header for all supported env vars.

---

## Manual deployment

Step-by-step equivalent of what `run-podman.sh` does automatically.

### Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| Podman (or Docker) | any recent | build images, run containers |
| git | any | clone repositories |
| JDK 21 | 21+ | compile/run backend (only if building JAR outside Docker) |
| Maven | 3.9+ | build backend (only if building JAR outside Docker) |

You also need a **GitLab OAuth2 token** for `git.epo.org` with read access to the repositories.

---

### Backend (search-report-service)

The `Dockerfile.prod` performs a complete multi-stage build — it clones all dependencies and compiles the JAR inside the container. No local JDK or Maven required.

#### Option A — Docker/Podman image (recommended)

```bash
# 1. Clone search-report-service source
git clone https://oauth2:<IPI_TOKEN>@git.epo.org/it-cooperation/search-report-service.git

# 2. Build the image (Dockerfile.prod clones front-office-parent and common-libs internally)
podman build --no-cache \
  -f search-report-service/Dockerfile.prod \
  --build-arg GIT_TOKEN=<IPI_TOKEN> \
  -t search-report-service:local \
  search-report-service/
```

With a corporate proxy:
```bash
podman build --no-cache \
  -f search-report-service/Dockerfile.prod \
  --build-arg GIT_TOKEN=<IPI_TOKEN> \
  --build-arg HTTP_PROXY=http://<host>:<port> \
  --build-arg HTTPS_PROXY=http://<host>:<port> \
  --build-arg PROXY_HOST=<host> \
  --build-arg PROXY_PORT=<port> \
  -t search-report-service:local \
  search-report-service/
```

#### Option B — Build JAR locally (requires JDK 21 + Maven 3.9)

The build requires two upstream libraries installed into your local Maven repository first:

```bash
# 1. Clone and install front-office-parent (parent POM only, non-recursive)
git clone https://oauth2:<IPI_TOKEN>@git.epo.org/it-cooperation/front-office-parent.git
mvn install -N -f front-office-parent/pom.xml -DskipTests=true -P '!gcp'

# 2. Clone and install common-libs
git clone https://oauth2:<IPI_TOKEN>@git.epo.org/it-cooperation/common-libs.git
mvn install -f common-libs/pom.xml -Dmaven.compiler.proc=full -DskipTests=true -P '!gcp'

# 3. Clone and build search-report-service
git clone https://oauth2:<IPI_TOKEN>@git.epo.org/it-cooperation/search-report-service.git
mvn clean package -f search-report-service/pom.xml -DskipTests=true -P '!gcp'
# JAR output: search-report-service/target/search-report-service-*.jar
```

#### Configuration (fo-configuration-ch)

The backend reads its runtime configuration (templates, locales, specs) from a mounted directory:

```bash
git clone https://oauth2:<IPI_TOKEN>@git.epo.org/it-cooperation/fo-configuration-ch.git
```

Mount as `/data/config` when starting the container (see below).

#### Start the backend container

```bash
# Clone configuration if not done above
git clone https://oauth2:<IPI_TOKEN>@git.epo.org/it-cooperation/fo-configuration-ch.git

podman network create srs-net 2>/dev/null || true

podman run -d \
  --name search-report-service \
  --network srs-net \
  -p 3215:8080 \
  -v "$(pwd)/fo-configuration-ch:/data/config" \
  -e SPRING_PROFILES_ACTIVE="prod" \
  -e IDENTITY_PROVIDER="azure" \
  -e CONFIGURATION_BASE_PATH="/data/config/" \
  -e DOSSIER_MOCK_ENABLED="true" \
  -e SEARCH_REPORT_SERVICE_CONTEXT_PATH="/search-report-service" \
  -e SEARCH_REPORT_SERVICE_PORT="8080" \
  search-report-service:local
```

For real Azure authentication (disable mock):
```bash
  -e DOSSIER_MOCK_ENABLED="false" \
  -e OPENID_ISSUER_URI="https://login.microsoftonline.com/a87b6d3d-d85e-4d9b-8704-6aed76a49444/v2.0" \
  -e OPENID_CLIENT_ID="<client-id>" \
  -e OPENID_CLIENT_SECRET="<client-secret>" \
  -e OPENID_REDIRECT_URI="https://<your-domain>/search-report-service/api/oauth/callback" \
```

Direct access (no nginx): `http://localhost:3215/search-report-service/actuator/health`

---

### Frontend (dtk-mfe)

#### What the Dockerfile does

The `dtk-mfe/Dockerfile` is a two-stage build:

**Stage 1 — builder** (`node:22.12.0-alpine`):

1. Copies the `dtk-mfe` repo contents into the container
2. Installs `git` (via apk) and `pnpm@10.25.0` (via npm)
3. Configures a git credential helper using `GIT_USERNAME`/`GIT_PASSWORD` build args
4. Runs `pnpm run docker:init --ref <DTK_REPO_REF> --ref-fe-common <DTK_FE_COMMON_REF> --cleanup`

`docker:init` (`dtk-cli/ci/init.cjs`) does the following in sequence:
  - `pnpm install --frozen-lockfile` — installs the dtk-mfe workspace's own tooling
  - Clones repositories into the workspace (from `.settings`):
    - `dtk-libs/dtk-fe-common` at `DTK_FE_COMMON_REF`
    - `dtk-mfe-shell` at `DTK_REPO_REF`
    - `dtk-mfes/dtk-mfe-actions`, `dtk-mfe-alerts`, `dtk-mfe-footer`, `dtk-mfe-form-details`, `dtk-mfe-header`, `dtk-mfe-import-contacts`, `dtk-mfe-legacy`, `dtk-mfe-page-builder`, `dtk-mfe-sidebar`, `dtk-mfe-websockets` at `DTK_REPO_REF`
  - Builds `dtk-fe-common`: `ci:install` → `ci:build` → `pnpm -r pack` (produces `.tgz`)
  - Replaces version references in all MFE `package.json` files with local `file:` paths pointing to the packed `.tgz`
  - `pnpm install --fix-lockfile` across all MFEs and shell (except `dtk-mfe-legacy`)
  - `pnpm run ci:build` across all MFEs and shell
  - Assembles `docker-build/` output folder:
    - `dtk-mfe-shell/dist` → `docker-build/dist` (shell bundle)
    - `dtk-mfes/*/dist/*.js` → `docker-build/dist/artifacts/` (MFE bundles)
    - `dtk-mfe-shell/public` → `docker-build/public` (static assets, `env.template.js`)
    - `dtk-mfe-shell/nginx/default_prd.dtk.conf.template` → `docker-build/nginx/`
    - `dtk-mfe-shell/env.sh` → `docker-build/env.sh` (runtime env injection script)
  - Removes all cloned repos and `node_modules` to reduce image size (`--cleanup`)

**Stage 2 — runtime** (`nginx:1.21.0-alpine`):

- Copies `docker-build/nginx/default_prd.dtk.conf.template` as the nginx config template
- Copies `docker-build/dist` → `/usr/share/nginx/html` (served static files)
- Copies `docker-build/public/env.template.js` → `/usr/share/nginx/html/`
- Copies `docker-build/env.sh` → `/docker-entrypoint.d/env.sh` (runs at container start to inject env vars into `env.template.js`)

---

#### Option A — Podman/Docker image

```bash
# Clone dtk-mfe
git clone https://oauth2:<IPI_TOKEN>@git.epo.org/it-cooperation/dtk-mfe.git

podman build \
  -f dtk-mfe/Dockerfile \
  --build-arg DTK_REPO_REF=develop \
  --build-arg DTK_FE_COMMON_REF=develop \
  --build-arg GIT_USERNAME=oauth2 \
  --build-arg GIT_PASSWORD=<IPI_TOKEN> \
  -t search-report-mfe:local \
  dtk-mfe/
```

With a corporate proxy (SSL inspection):
```bash
podman build \
  -f dtk-mfe/Dockerfile \
  --build-arg DTK_REPO_REF=develop \
  --build-arg DTK_FE_COMMON_REF=develop \
  --build-arg GIT_USERNAME=oauth2 \
  --build-arg GIT_PASSWORD=<IPI_TOKEN> \
  --build-arg HTTP_PROXY=http://<host>:<port> \
  --build-arg HTTPS_PROXY=http://<host>:<port> \
  -t search-report-mfe:local \
  dtk-mfe/
```

> **Corporate SSL inspection note:** `run-podman.sh` automatically patches `dtk-mfe/Dockerfile` before building — it switches Alpine apk repos to HTTP, disables npm strict-ssl before installing pnpm, and sets `NODE_TLS_REJECT_UNAUTHORIZED=0`. If building manually on such a network, apply those same patches to `dtk-mfe/Dockerfile` first.

---

#### Option B — Fully manual build (requires Node.js 22 + pnpm 10)

Prerequisites: Node.js 22.12.0, pnpm 10.25.0, git.

```bash
# 1. Clone dtk-mfe
git clone https://oauth2:<IPI_TOKEN>@git.epo.org/it-cooperation/dtk-mfe.git
cd dtk-mfe

# 2. Configure git credentials (used by docker:init when cloning sub-repos)
git config --global credential.helper \
  '!f() { echo "username=oauth2"; echo "password=<IPI_TOKEN>"; }; f'

# 3. Install dtk-mfe workspace tooling
pnpm install --frozen-lockfile

# 4. Clone all sub-repos and build everything (equivalent to what docker:init does)
pnpm run docker:init --ref develop --ref-fe-common develop

# Output is in docker-build/:
#   docker-build/dist/             — shell + all MFE bundles
#   docker-build/dist/artifacts/   — individual MFE .js files
#   docker-build/public/           — static assets, env.template.js
#   docker-build/nginx/            — nginx config template
#   docker-build/env.sh            — runtime env injection script
```

After building, serve with nginx pointing document root at `docker-build/dist/`, or pack the output into a container image manually.

#### Patch importmap.json

The MFE loads its micro-frontend bundles from a URL listed in `fo-configuration-ch`. By default this points to a GCS bucket (remote). For local use, patch it to serve from nginx instead:

```bash
sed -i 's|https://storage.googleapis.com/[^"]*develop/|{{basePath}}/artifacts/|g' \
  fo-configuration-ch/apps/back-office/-shell/importmap.json
```

#### nginx configuration

The MFE container uses nginx to serve static assets and reverse-proxy `/search-report-service/` to the backend. Create a template file:

```bash
mkdir -p nginx-templates
cat > nginx-templates/default.conf.template << 'EOF'
server {
  listen 8080;

  location /search-report-service/ {
    proxy_pass http://search-report-service:8080;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_read_timeout 60s;
  }

  location /srs {
    rewrite /srs/(.*) /$1 break;
    root /usr/share/nginx/html;
    index index.html;
    try_files $uri $uri/ /index.html;
  }

  location / {
    root /usr/share/nginx/html;
    index index.html;
    try_files $uri $uri/ /index.html;
  }
}
EOF
```

For HTTPS (TLS), place `server.crt` and `server.key` in a directory (e.g. `/etc/certs`) and use:
```
listen 8443 ssl;
ssl_certificate /etc/nginx/certs/server.crt;
ssl_certificate_key /etc/nginx/certs/server.key;
```

#### Start the frontend container

Certificates must be mounted into the container at `/etc/nginx/certs/`. The directory must contain exactly two files: `server.crt` (certificate chain) and `server.key` (private key). Any algorithm (RSA, ECDSA) and any issuer (self-signed, corporate CA, Let's Encrypt) works.

```bash
podman run -d \
  --name search-report-mfe \
  --network srs-net \
  -p 443:8443 \
  -v "$(pwd)/nginx-templates:/etc/nginx/templates" \
  -v "/path/to/certs:/etc/nginx/certs:ro" \
  -e DTK_BASE_PATH="/srs" \
  -e DTK_SHELL_ID="back-office" \
  -e DTK_CONFIGURATION_SERVICE_URL="/search-report-service" \
  -e DTK_KEYCLOAK_REALM="" \
  -e DTK_KEYCLOAK_CLIENT="" \
  -e ENVIRONMENT="develop" \
  search-report-mfe:local
```

The nginx template must use the TLS listen directive (see nginx configuration section above).

---

### Access points

| URL | Description |
|-----|-------------|
| `https://<your-domain>/srs` | MFE frontend |
| `https://<your-domain>/search-report-service` | Backend via nginx proxy |
| `http://localhost:3215/search-report-service/actuator/health` | Backend direct (debug, no TLS) |

---

### Monitoring

```bash
podman logs -f search-report-service
podman logs -f search-report-mfe
```

Logging levels (pass as env vars to the backend container):

```
APP_LOGGING_LEVEL    — org.epo.itc logging  (default: INFO)
ROOT_LOGGING_LEVEL   — root logger          (default: WARN)
SPRING_LOGGING_LEVEL — Spring framework     (default: WARN)
SQL_LOGGING_LEVEL    — Hibernate SQL        (default: WARN)
```
