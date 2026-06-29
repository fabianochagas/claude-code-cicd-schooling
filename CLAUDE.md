# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Purpose

CI/CD pipeline scaffold for a Laravel + PostgreSQL application. Implements immutable infrastructure (Docker) with GitHub Actions. No Laravel application code exists yet — this repo contains only the pipeline and container infrastructure.

## Architecture

### Environments & Triggers

| Environment | Branch/Trigger | Workflow |
|---|---|---|
| Development | push to `develop` | `.github/workflows/ci-cd-dev.yml` |
| Pre-Production | push to `staging` | `.github/workflows/ci-cd-preprod.yml` |
| Production | tag `v*.*.*` | `.github/workflows/ci-cd-prod.yml` |

### Pipeline Stages (all three environments)

1. **test** — PHP 8.3 + Composer + ephemeral PostgreSQL 16 service container → Pest (`--parallel --coverage --min=80`) + Larastan
2. **build** — Multi-stage Docker build → push to GHCR tagged with SHA + environment name
3. **deploy** — SSH into server: `docker login` → `docker pull` → `docker run --rm --network host` migrations → container swap

### Docker Image

Multi-stage build (`Dockerfile`):
- Stage 1 (`vendor`): `composer:2.7` — installs production PHP deps (`--no-dev`)
- Stage 2 (`assets`): `node:20-alpine` — builds frontend assets via Vite
- Stage 3 (`production`): `php:8.3-fpm-alpine` + Nginx + Supervisor

Supervisor manages both `php-fpm` and `nginx` inside a single container on port 80.

`docker/entrypoint.sh` warms Laravel caches on server start. Pass `RUN_MIGRATIONS=true` to run `php artisan migrate --force` before the server starts.

### Migrations Pattern

Migrations run **server-side via SSH** (not from the GitHub runner) using `docker run --rm --network host` so the migration container reaches the DB through the server's private network. This avoids requiring the DB to be publicly accessible.

### Secrets

Secrets are environment-scoped in GitHub (`Settings → Environments`). Prefixes: `DEV_`, `PREPROD_`, `PROD_`. Required per environment: `APP_KEY`, `DB_HOST`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`, `SSH_HOST`, `SSH_USER`, `SSH_KEY`.

`.env.ci` is committed — safe CI defaults only, no real secrets.

## Adding a Laravel Application

When a real Laravel app is added:
1. `composer.json` and `composer.lock` must exist at repo root (consumed by Dockerfile stage 1)
2. `package.json`, `package-lock.json`, and `vite.config.js` must exist (consumed by Dockerfile stage 2)
3. `resources/` directory must exist for Vite
4. `phpstan.neon` + Larastan dev dependency required for the static analysis step
5. Run `docker build .` locally to verify the image builds before pushing

## Known Architectural Limitations

- **Container swap has ~5–15s downtime** — `docker stop` → `docker run` gap. Zero-downtime requires blue/green or a reverse-proxy cutover (Caddy, Traefik, Kamal).
- **`vite.config.js` hardcoded** in Dockerfile stage 2 — projects using `vite.config.ts` must update that COPY line.
