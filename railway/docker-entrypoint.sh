#!/bin/sh
# openGym — Railway container entrypoint.
#
# Starts the API and nginx in one container and keeps them tied together: if either dies,
# the container exits and Railway restarts it, rather than limping along half-broken.
set -eu

# --- Port assignment ------------------------------------------------------------------
# Railway injects PORT for the public listener. The API *also* reads PORT (api/server.js),
# so if it inherited this value both processes would fight over the same port. nginx takes
# Railway's PORT; the API is pinned to 3000, which only nginx talks to.
export PORT="${PORT:-8080}"

# nginx config is upstream's own web/nginx.conf.template, so its headers and proxy fixes
# arrive with every release. It is rendered in a subshell so PORT=3000 never leaks into the
# API's environment.
(
  # 1. Upstream's defaults (ENV lines of web/Dockerfile), for anything not already set.
  #    A variable a new release adds to the template arrives with its default.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    eval "[ -n \"\${${line%%=*}+x}\" ]" || eval "export $line"
  done < /etc/nginx/nginx-defaults.env

  # 2. Same-container wiring, always: nginx listens on Railway's PORT and proxies /api to the
  #    API on 127.0.0.1:3000. RESOLVER is required by the template but unused, since an
  #    IP-literal backend needs no DNS.
  export NGINX_PORT="$PORT" BACKEND=127.0.0.1 PORT=3000 RESOLVER=127.0.0.11

  # 3. Substitute exactly the ${VARS} the template uses, so nginx's own $host/$uri survive.
  vars="$(grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' /etc/nginx/nginx.conf.template | sort -u | tr '\n' ' ')"
  for v in $vars; do
    name="${v#??}"; name="${name%?}"
    eval "[ -n \"\${${name}+x}\" ]" || echo "WARNING: nginx template variable ${name} has no value" >&2
  done
  envsubst "$vars" < /etc/nginx/nginx.conf.template > /etc/nginx/http.d/default.conf
)
nginx -t -q || { echo "FATAL: rendered nginx config is invalid" >&2; exit 1; }

# --- WebAuthn identity ----------------------------------------------------------------
# Passkeys are bound to an exact hostname and require HTTPS. The Railway template sets
# these explicitly; this fallback keeps a plain `railway up` (no template) working too.
# Note: changing RP_ID after users register invalidates their existing passkeys.
if [ -n "${RAILWAY_PUBLIC_DOMAIN:-}" ]; then
  export ORIGIN="${ORIGIN:-https://${RAILWAY_PUBLIC_DOMAIN}}"
  export RP_ID="${RP_ID:-${RAILWAY_PUBLIC_DOMAIN}}"
fi

DATA_DIR="${DATA_DIR:-/data}"
export DATA_DIR
mkdir -p "$DATA_DIR" 2>/dev/null || true

# Probe with a real write: `[ -w ]` only inspects permission bits, and for root those
# still look writable on a read-only mount, so it would wave through a broken volume.
if ! touch "$DATA_DIR/.write-probe" 2>/dev/null; then
  echo "FATAL: DATA_DIR ($DATA_DIR) is not writable. Attach a Railway volume mounted there," >&2
  echo "       otherwise accounts and passkeys are lost on every redeploy." >&2
  exit 1
fi
rm -f "$DATA_DIR/.write-probe"

echo "openGym $(cat /.version 2>/dev/null || echo unknown) starting — nginx :${PORT} → api :3000 | RP_ID=${RP_ID:-localhost} ORIGIN=${ORIGIN:-http://localhost:8080} DATA_DIR=${DATA_DIR}"

# --- Processes ------------------------------------------------------------------------
# PORT=3000 is scoped to this command only, overriding the exported value above.
PORT=3000 node /app/api/server.js &
API_PID=$!

nginx -g 'daemon off;' &
NGINX_PID=$!

shutdown() {
  kill -TERM "$API_PID" "$NGINX_PID" 2>/dev/null || true
  exit 0
}
trap shutdown TERM INT

# Supervise both processes. BusyBox ash does NOT support bash's `wait -n` (it blocks until
# a *specific* job finishes rather than returning on the first exit), so a dead API would
# otherwise leave nginx serving a frontend that can't log anyone in — a 502 that looks
# "up" to Railway. Poll instead: the moment either side is gone, take the whole container
# down so Railway restarts it.
while kill -0 "$API_PID" 2>/dev/null && kill -0 "$NGINX_PID" 2>/dev/null; do
  sleep 2
done

if ! kill -0 "$API_PID" 2>/dev/null; then
  echo "FATAL: the API process exited — shutting down so Railway restarts the container." >&2
else
  echo "FATAL: nginx exited — shutting down so Railway restarts the container." >&2
fi

kill -TERM "$API_PID" "$NGINX_PID" 2>/dev/null || true
exit 1
