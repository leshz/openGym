# openGym — single-container image for Railway.
#
# Build context is the repository root (see /railway.json). Everything Railway-specific lives
# in railway/ so merging upstream releases into this fork never touches it.
#
# Railway deploys individual services, not docker-compose. Upstream splits into `web`
# (nginx) + `api` (node) + a one-shot `media` downloader. Passkeys (WebAuthn) require the
# app and its API to share ONE origin, so both run here in a single container: nginx serves
# the SPA on Railway's $PORT and proxies /api to node on 127.0.0.1:3000.

# --- Frontend (mirrors web/Dockerfile) ----------------------------------------------------
# --platform=$BUILDPLATFORM: Vite output is arch-independent, and QEMU-emulated npm installs
# are known to corrupt esbuild/rollup's native binaries (upstream documents this).
FROM --platform=$BUILDPLATFORM node:22-alpine AS build
# The frontend imports api/coach/core via ../../../api/coach/core, so both keep their
# relative position from the repository.
WORKDIR /app/frontend
COPY frontend/package.json frontend/package-lock.json* ./
# --ignore-scripts: skips @capacitor/assets -> sharp (app-icon tooling, not needed here).
RUN npm ci --ignore-scripts
COPY api/coach/core/ /app/api/coach/core/
COPY frontend/ ./
# Exercise media is served from jsDelivr instead of a ~140 MB volume, pinned to the dataset
# commit the mobile build (build:mobile) uses.
RUN sha="$(grep -oE 'exercises-dataset@[0-9a-f]{40}' package.json | head -n 1 | cut -d@ -f2)" \
 && sha="${sha:-7455efae41b330c265e7cd4b78dfa848e7ce5ebd}" \
 && VITE_IMG_BASE="https://cdn.jsdelivr.net/gh/hasaneyldrm/exercises-dataset@${sha}/images/" \
    VITE_GIF_BASE="https://cdn.jsdelivr.net/gh/hasaneyldrm/exercises-dataset@${sha}/videos/" \
    npm run build \
 && echo "v$(node -p 'require("./package.json").version')" > /tmp/version

# --- nginx template defaults --------------------------------------------------------------
# The ENV defaults web/Dockerfile gives its nginx template, as KEY=VALUE lines. The
# entrypoint applies them, so a variable added to the template by a new release arrives
# with its default instead of rendering empty.
FROM alpine:3 AS nginx-defaults
COPY web/Dockerfile /tmp/web.Dockerfile
RUN sed -n 's/^ENV \([A-Z_][A-Z0-9_]*=.*\)$/\1/p' /tmp/web.Dockerfile > /nginx-defaults.env

# --- API dependencies (mirrors api/Dockerfile, default target) ----------------------------
FROM node:22-alpine AS api
WORKDIR /app/api
COPY api/ ./
# --omit=optional: no AI runtime (Agent SDK / Codex), same as upstream's default image.
RUN npm ci --omit=dev --omit=optional && npm cache clean --force && rm -rf test

# --- Runtime -----------------------------------------------------------------------------
FROM node:22-alpine
# gettext provides envsubst, used to render the nginx template at start-up.
RUN apk upgrade --no-cache && apk add --no-cache nginx gettext
# Coach jobs drop to this user and fail closed if it does not exist (api/Dockerfile).
RUN adduser -D -H -s /sbin/nologin coach

COPY --from=build /app/frontend/dist /usr/share/nginx/html
COPY --from=build /tmp/version /.version
COPY --from=api /app/api /app/api
COPY --from=nginx-defaults /nginx-defaults.env /etc/nginx/nginx-defaults.env
COPY web/nginx.conf.template /etc/nginx/nginx.conf.template

COPY railway/docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

ENV NODE_ENV=production \
    DATA_DIR=/data \
    PORT=8080

# /data holds accounts, passkeys, the session secret and VAPID keys. Railway manages the
# volume itself and REJECTS a Dockerfile VOLUME instruction, so the mount is declared in the
# service config (mount path /data) rather than here.
EXPOSE 8080

ENTRYPOINT ["/docker-entrypoint.sh"]
