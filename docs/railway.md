# Railway Deployment

Deploy Finch to Railway without baking cookies or local auth material into the image.

## Services

Create:

- one Finch web service from this repo
- one Redis service
- one Railway volume mounted for local Finch data

## Required variables

Set these on the Finch service:

- `NITTER_ENV=production`
- `NITTER_HOSTNAME=<your public hostname>`
- `NITTER_HTTPS=true`
- `NITTER_HMAC_KEY=<32+ char random secret>`
- `NITTER_ENABLE_ADMIN=false`
- `NITTER_REDIS_HOST=<redis private host>`
- `NITTER_REDIS_PORT=<redis private port>`
- `NITTER_REDIS_PASSWORD=<redis password if needed>`
- `NITTER_LOCAL_DATA_PATH=/data/finch_local.json`

For X sessions, set one of:

- `NITTER_SESSIONS_JSONL`
- `NITTER_SESSIONS_JSONL_B64`

Do not commit `sessions.jsonl` or raw config files for production.

## Notes

- Railway provides `PORT`; Finch now reads it automatically.
- The container entrypoint writes session secrets to `/tmp/finch/sessions.jsonl` only at runtime.
- Production startup now refuses weak defaults such as `secretkey`, `enableAdmin=true`, `https=false`, or `hostname=127.0.0.1`.
- Use a mounted Railway volume at `/data` so Finch local Following/Lists data persists across deploys.
