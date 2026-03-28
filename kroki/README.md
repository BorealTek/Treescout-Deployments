# Kroki - Standalone Diagram Renderer

This stack runs Kroki independently from the app stack, mirroring the separate lifecycle pattern used by cloudflared.

## Start

```bash
cd deployment/kroki
docker compose up -d
docker compose logs -f
```

Kroki listens on `127.0.0.1:8001` on the host.

## App Configuration

Set these environment variables for the app:

```env
MIDDLEMAN_KROKI_ENABLED=true
MIDDLEMAN_KROKI_URL=http://host.docker.internal:8001
MIDDLEMAN_KROKI_TIMEOUT=10
```

Then reload config/views:

```bash
php artisan config:clear
php artisan view:clear
```

## Health Check

```bash
curl -sS http://127.0.0.1:8001/health
```

Expected response includes `"status":"up"`.

## Notes

- The topology page renders the diagram server-side via `GET /middleman/topology/diagram.svg`.
- If Kroki is unavailable, the page still exposes DOT and JSON so diagnostics remain usable.
