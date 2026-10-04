# openGym on Railway

This fork of [DuarteSantos8/openGym](https://github.com/DuarteSantos8/openGym) runs openGym as a
**single Railway service**: nginx and the API share one container, behind one origin, which
passkeys require. Everything Railway-specific is in `railway/`, `/railway.json` and
`.github/workflows/sync-upstream-release.yml`; the rest of the repository is upstream, unmodified.

## How it stays up to date

1. Every day, `sync-upstream-release.yml` merges the newest upstream release (`vX.Y.Z`) into
   `main`. It can also be run by hand: `gh workflow run sync-upstream-release.yml`.
2. Railway is connected to `main` and deploys every push.
3. The container logs `openGym vX.Y.Z starting` at boot, so the running version is visible.

If a merge conflicts, the workflow fails (GitHub emails you) and nothing is pushed. If a release
builds but fails its healthcheck, Railway keeps the previous deployment running.

**Roll back:** revert the merge commit on `main`, or redeploy an earlier deployment in Railway.
The `/data` format only migrates forward, so take a volume backup before you jump versions.

### One-time setup of the sync

The workflow needs a `UPSTREAM_SYNC_TOKEN` secret: a fine-grained personal access token for this
repository with **Contents: read/write** and **Workflows: read/write**. The default
`GITHUB_TOKEN` cannot push merges that change `.github/workflows/`, which upstream releases often
do.

```bash
gh secret set UPSTREAM_SYNC_TOKEN -R leshz/openGym
```

Upstream's own workflows (`docker-publish`, `mirror`, `pages`) are disabled in this fork. They
publish upstream's images and site and would fail here.

## Deploying

Create a service from this repository (branch `main`). `railway.json` selects
`railway/Dockerfile`, the `/api/health` healthcheck and a single replica.

**1. Attach a volume at `/data`.** It holds accounts, passkeys, workout history, the
session-signing secret and the push keys. Without it, every redeploy wipes them.

**2. Set the variables:**

| Variable | Value | Why |
|---|---|---|
| `RP_ID` | `${{RAILWAY_PUBLIC_DOMAIN}}` | Hostname passkeys are bound to |
| `ORIGIN` | `https://${{RAILWAY_PUBLIC_DOMAIN}}` | Full origin; enables `Secure` cookies |
| `RP_NAME` | `openGym` | Name in the browser's passkey prompt |
| `DATA_DIR` | `/data` | Volume mount path |
| `PORT` | `8080` | Port nginx listens on |

Optional variables (`ADMIN_UIDS`, `INVITE_ONLY`, `ALLOW_GUEST`, `SESSION_DAYS`, `AUDIT_*`,
`COACH_DISABLED`, `VAPID_SUBJECT`, `CF_CONNECTING_IP`, `MEDIA_UPLOAD_MAX`, …) are documented in
the upstream [`.env.example`](../.env.example).

**3. Domain: target port `8080`.** nginx listens on 8080; the API on 3000 is internal. Railway
can pick 3000 on its own, and then `/` answers `{"error":"not found"}` while `/api/health` still
works.

**4. Pick the final domain before anyone registers.** Passkeys are bound to the hostname.
Changing `RP_ID` later invalidates every existing passkey.

## How this differs from upstream's compose setup

| | Upstream (`docker compose`) | Railway (`railway/`) |
|---|---|---|
| Services | `web` + `api` + `media` | one container: nginx + API |
| nginx config | `web/nginx.conf.template` | the same template, rendered with a `127.0.0.1:3000` backend |
| Listen port | `NGINX_PORT` (80) | Railway's `$PORT` |
| Exercise media | ~140 MB downloaded into a volume | jsDelivr CDN, pinned to the dataset commit `build:mobile` uses |
| AI runtime | `default` or `coach` target | `default` (no Agent SDK / Codex; HTTP providers still work) |

nginx template variables get their defaults from the `ENV` lines of `web/Dockerfile`, so a
variable added by a new release does not leave the config empty. The entrypoint validates the
rendered config (`nginx -t`) and exits if it is invalid.

## Running locally

```bash
docker build -f railway/Dockerfile -t opengym-railway .
docker run --rm -p 8080:8080 -e PORT=8080 -v opengym-data:/data opengym-railway
curl localhost:8080/api/health     # {"ok":true,"users":0}
```

## Operations

- **Single replica by design.** State is JSON files on the volume; concurrent replicas would
  corrupt `db.json`.
- **The container exits if either process dies**, so Railway restarts it instead of serving a
  frontend whose sign-in returns 502.
- **Backups:** `railway ssh --service opengym`, then `tar czf - /data > backup.tar.gz`. Users can
  also export their own data from Settings.
- `railway.json` (config as code) is deprecated by Railway on 2026-12-01; its settings can be set
  in the service UI instead.
