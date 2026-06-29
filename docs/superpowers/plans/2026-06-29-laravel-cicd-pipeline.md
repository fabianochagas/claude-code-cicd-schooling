# Laravel CI/CD Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a complete GitHub Actions CI/CD pipeline for Laravel + PostgreSQL using Docker immutable infrastructure, covering dev and prod environments.

**Architecture:** Multi-stage Dockerfile produces a single self-contained image (PHP-FPM + Nginx via Supervisor). GitHub Actions runs tests against an ephemeral PostgreSQL service container, builds and pushes the image to GHCR, then SSHs into the target server to run migrations and swap the container.

**Tech Stack:** PHP 8.3-fpm-alpine, Nginx, Supervisor, PostgreSQL 16, Docker multi-stage build, GitHub Actions, GHCR, Pest, Larastan/PHPStan, `shivammathur/setup-php`, `docker/build-push-action`, `appleboy/ssh-action`.

## Global Constraints

- PHP version: 8.3+
- PostgreSQL version: 16
- No Jenkins, no Ansible, no configuration managers
- All CI/CD lives in `.github/workflows/`
- All secrets injected via GitHub Secrets — never committed
- Dev trigger: push to `develop`
- Prod trigger: tag matching `v*.*.*`
- Migrations run BEFORE container swap (zero-downtime pattern)

---

### Task 1: Docker Infrastructure

**Files:**
- Create: `Dockerfile`
- Create: `docker/nginx.conf`
- Create: `docker/supervisord.conf`
- Create: `docker/php.ini`
- Create: `docker/entrypoint.sh`

**Interfaces:**
- Produces: runnable image tagged `:dev` or `:vX.Y.Z` consumed by deploy jobs
- Exposes port 80 (nginx → php-fpm on 127.0.0.1:9000)
- `RUN_MIGRATIONS=true` env var triggers `php artisan migrate --force` at container start

- [ ] **Step 1: Create `docker/nginx.conf`**

```nginx
server {
    listen 80;
    root /var/www/html/public;
    index index.php;

    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";

    charset utf-8;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    error_page 404 /index.php;

    location ~ \.php$ {
        fastcgi_pass 127.0.0.1:9000;
        fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
```

- [ ] **Step 2: Create `docker/supervisord.conf`**

```ini
[supervisord]
nodaemon=true
logfile=/dev/stdout
logfile_maxbytes=0
pidfile=/tmp/supervisord.pid

[program:php-fpm]
command=php-fpm -F
autostart=true
autorestart=true
priority=10
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

[program:nginx]
command=nginx -g 'daemon off;'
autostart=true
autorestart=true
priority=20
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
```

- [ ] **Step 3: Create `docker/php.ini`**

```ini
opcache.enable=1
opcache.memory_consumption=256
opcache.max_accelerated_files=20000
opcache.validate_timestamps=0
opcache.interned_strings_buffer=16
expose_php=Off
upload_max_filesize=64M
post_max_size=64M
```

- [ ] **Step 4: Create `docker/entrypoint.sh`**

```bash
#!/bin/sh
set -e

if [ "$RUN_MIGRATIONS" = "true" ]; then
    echo "Running migrations..."
    php artisan migrate --force
fi

exec "$@"
```

- [ ] **Step 5: Create `Dockerfile`**

```dockerfile
# syntax=docker/dockerfile:1

# ─── Stage 1: PHP dependencies ───────────────────────────────────────────────
FROM composer:2.7 AS vendor

WORKDIR /app

COPY composer.json composer.lock ./

RUN composer install \
    --no-dev \
    --no-interaction \
    --no-scripts \
    --prefer-dist \
    --optimize-autoloader

# ─── Stage 2: Frontend assets ─────────────────────────────────────────────────
FROM node:20-alpine AS assets

WORKDIR /app

COPY package.json package-lock.json ./
# Adjust if you use vite.config.ts or similar
COPY vite.config.js ./
COPY resources/ resources/

RUN npm ci && npm run build

# ─── Stage 3: Production image ────────────────────────────────────────────────
FROM php:8.3-fpm-alpine AS production

# System deps + PHP extensions
RUN apk add --no-cache \
        nginx \
        supervisor \
        libpq \
        libpq-dev \
    && docker-php-ext-install \
        pdo \
        pdo_pgsql \
        opcache \
        pcntl \
    && apk del libpq-dev \
    && rm -rf /var/cache/apk/*

# PHP production config
COPY docker/php.ini $PHP_INI_DIR/conf.d/app.ini

# App source
WORKDIR /var/www/html
COPY . .

# Overwrite vendor and built assets from previous stages
COPY --from=vendor /app/vendor vendor/
COPY --from=assets /app/public/build public/build/

# Service configs
COPY docker/nginx.conf /etc/nginx/http.d/default.conf
COPY docker/supervisord.conf /etc/supervisord.conf
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod +x /usr/local/bin/entrypoint.sh \
    && chown -R www-data:www-data storage bootstrap/cache \
    && php artisan config:cache \
    && php artisan route:cache \
    && php artisan view:cache

EXPOSE 80

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisord.conf"]
```

- [ ] **Step 6: Validate build locally**

```bash
docker build --no-cache -t app:test .
```

Expected: `Successfully built <sha>` — no errors. Fix any Alpine package names or extension errors before proceeding.

- [ ] **Step 7: Commit**

```bash
git add Dockerfile docker/
git commit -m "feat: add multi-stage Dockerfile with PHP-FPM, Nginx, Supervisor"
```

---

### Task 2: CI Environment File

**Files:**
- Create: `.env.ci`

**Interfaces:**
- Consumed by: `test` jobs in both workflow files via `cp .env.ci .env`

- [ ] **Step 1: Create `.env.ci`**

```env
APP_NAME=Laravel
APP_ENV=testing
APP_KEY=
APP_DEBUG=true
APP_URL=http://localhost

LOG_CHANNEL=stderr

DB_CONNECTION=pgsql
DB_HOST=127.0.0.1
DB_PORT=5432
DB_DATABASE=testing
DB_USERNAME=postgres
DB_PASSWORD=postgres

CACHE_STORE=array
SESSION_DRIVER=array
QUEUE_CONNECTION=sync
MAIL_MAILER=array

BROADCAST_CONNECTION=log
FILESYSTEM_DISK=local
```

- [ ] **Step 2: Verify `.env.ci` not in `.gitignore`**

Run: `grep -n '.env.ci' .gitignore`

Expected: no match (`.env.ci` is safe to commit — no real secrets, only CI defaults).

- [ ] **Step 3: Commit**

```bash
git add .env.ci
git commit -m "feat: add CI environment template"
```

---

### Task 3: Development Workflow

**Files:**
- Create: `.github/workflows/ci-cd-dev.yml`

**Interfaces:**
- Trigger: `push` to `develop` branch
- Jobs: `test` → `build` → `deploy` (sequential, each needs prior)
- Pushes image: `ghcr.io/<owner>/<repo>:dev` and `ghcr.io/<owner>/<repo>:dev-<sha>`
- Deploy reads secrets prefixed `DEV_`

- [ ] **Step 1: Create `.github/workflows/ci-cd-dev.yml`**

```yaml
name: CI/CD — Development

on:
  push:
    branches: [develop]

env:
  REGISTRY: ghcr.io
  IMAGE_NAME: ${{ github.repository }}

jobs:
  # ─── Job 1: Tests & Static Analysis ────────────────────────────────────────
  test:
    name: Tests & Static Analysis
    runs-on: ubuntu-latest

    services:
      postgres:
        image: postgres:16-alpine
        env:
          POSTGRES_DB: testing
          POSTGRES_USER: postgres
          POSTGRES_PASSWORD: postgres
        ports:
          - 5432:5432
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5

    steps:
      - uses: actions/checkout@v4

      - name: Setup PHP 8.3
        uses: shivammathur/setup-php@v2
        with:
          php-version: '8.3'
          extensions: pdo_pgsql, pcov
          coverage: pcov

      - name: Cache Composer dependencies
        uses: actions/cache@v4
        with:
          path: vendor
          key: composer-${{ hashFiles('composer.lock') }}
          restore-keys: composer-

      - name: Install dependencies
        run: composer install --no-interaction --prefer-dist --optimize-autoloader

      - name: Prepare environment
        run: |
          cp .env.ci .env
          php artisan key:generate

      - name: Run migrations
        env:
          DB_CONNECTION: pgsql
          DB_HOST: 127.0.0.1
          DB_PORT: 5432
          DB_DATABASE: testing
          DB_USERNAME: postgres
          DB_PASSWORD: postgres
        run: php artisan migrate --force

      - name: Run Pest
        env:
          DB_CONNECTION: pgsql
          DB_HOST: 127.0.0.1
          DB_PORT: 5432
          DB_DATABASE: testing
          DB_USERNAME: postgres
          DB_PASSWORD: postgres
        run: php artisan test --parallel --coverage --min=80

      - name: Run Larastan
        run: ./vendor/bin/phpstan analyse --memory-limit=512M

  # ─── Job 2: Build & Push Docker Image ──────────────────────────────────────
  build:
    name: Build & Push Image
    needs: test
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write

    steps:
      - uses: actions/checkout@v4

      - name: Login to GHCR
        uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Build and push
        uses: docker/build-push-action@v5
        with:
          context: .
          push: true
          tags: |
            ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:dev
            ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:dev-${{ github.sha }}
          cache-from: type=gha
          cache-to: type=gha,mode=max

  # ─── Job 3: Deploy to Development ──────────────────────────────────────────
  deploy:
    name: Deploy to Development
    needs: build
    runs-on: ubuntu-latest
    environment: development

    steps:
      - name: Run migrations
        run: |
          docker run --rm \
            -e APP_ENV=development \
            -e APP_KEY=${{ secrets.DEV_APP_KEY }} \
            -e DB_HOST=${{ secrets.DEV_DB_HOST }} \
            -e DB_PORT=5432 \
            -e DB_DATABASE=${{ secrets.DEV_DB_NAME }} \
            -e DB_USERNAME=${{ secrets.DEV_DB_USER }} \
            -e DB_PASSWORD=${{ secrets.DEV_DB_PASSWORD }} \
            ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:dev-${{ github.sha }} \
            php artisan migrate --force

      - name: Swap container on server
        uses: appleboy/ssh-action@v1
        with:
          host: ${{ secrets.DEV_SSH_HOST }}
          username: ${{ secrets.DEV_SSH_USER }}
          key: ${{ secrets.DEV_SSH_KEY }}
          script: |
            docker pull ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:dev-${{ github.sha }}
            docker stop app-dev || true
            docker rm app-dev || true
            docker run -d \
              --name app-dev \
              --restart unless-stopped \
              -p 80:80 \
              -e APP_ENV=development \
              -e APP_KEY=${{ secrets.DEV_APP_KEY }} \
              -e DB_HOST=${{ secrets.DEV_DB_HOST }} \
              -e DB_DATABASE=${{ secrets.DEV_DB_NAME }} \
              -e DB_USERNAME=${{ secrets.DEV_DB_USER }} \
              -e DB_PASSWORD=${{ secrets.DEV_DB_PASSWORD }} \
              ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:dev-${{ github.sha }}
            docker image prune -f
```

- [ ] **Step 2: Validate YAML syntax**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci-cd-dev.yml'))" && echo "YAML OK"
```

Expected: `YAML OK`

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ci-cd-dev.yml
git commit -m "feat: add GitHub Actions CI/CD workflow for development environment"
```

---

### Task 4: Production Workflow

**Files:**
- Create: `.github/workflows/ci-cd-prod.yml`

**Interfaces:**
- Trigger: `push` of tag matching `v*.*.*`
- Pushes image: `ghcr.io/<owner>/<repo>:latest`, `:prod`, `:<tag>` (e.g. `v1.2.3`)
- Deploy reads secrets prefixed `PROD_`
- Migrations run from CI runner BEFORE container swap

- [ ] **Step 1: Create `.github/workflows/ci-cd-prod.yml`**

```yaml
name: CI/CD — Production

on:
  push:
    tags:
      - 'v*.*.*'

env:
  REGISTRY: ghcr.io
  IMAGE_NAME: ${{ github.repository }}

jobs:
  # ─── Job 1: Tests & Static Analysis ────────────────────────────────────────
  test:
    name: Tests & Static Analysis
    runs-on: ubuntu-latest

    services:
      postgres:
        image: postgres:16-alpine
        env:
          POSTGRES_DB: testing
          POSTGRES_USER: postgres
          POSTGRES_PASSWORD: postgres
        ports:
          - 5432:5432
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5

    steps:
      - uses: actions/checkout@v4

      - name: Setup PHP 8.3
        uses: shivammathur/setup-php@v2
        with:
          php-version: '8.3'
          extensions: pdo_pgsql, pcov
          coverage: pcov

      - name: Cache Composer dependencies
        uses: actions/cache@v4
        with:
          path: vendor
          key: composer-${{ hashFiles('composer.lock') }}
          restore-keys: composer-

      - name: Install dependencies
        run: composer install --no-interaction --prefer-dist --optimize-autoloader

      - name: Prepare environment
        run: |
          cp .env.ci .env
          php artisan key:generate

      - name: Run migrations
        env:
          DB_CONNECTION: pgsql
          DB_HOST: 127.0.0.1
          DB_PORT: 5432
          DB_DATABASE: testing
          DB_USERNAME: postgres
          DB_PASSWORD: postgres
        run: php artisan migrate --force

      - name: Run Pest
        env:
          DB_CONNECTION: pgsql
          DB_HOST: 127.0.0.1
          DB_PORT: 5432
          DB_DATABASE: testing
          DB_USERNAME: postgres
          DB_PASSWORD: postgres
        run: php artisan test --parallel --coverage --min=80

      - name: Run Larastan
        run: ./vendor/bin/phpstan analyse --memory-limit=512M

  # ─── Job 2: Build & Push Docker Image ──────────────────────────────────────
  build:
    name: Build & Push Image
    needs: test
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write

    outputs:
      version: ${{ steps.meta.outputs.version }}

    steps:
      - uses: actions/checkout@v4

      - name: Extract version from tag
        id: meta
        run: echo "version=${GITHUB_REF#refs/tags/}" >> "$GITHUB_OUTPUT"

      - name: Login to GHCR
        uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Build and push
        uses: docker/build-push-action@v5
        with:
          context: .
          push: true
          tags: |
            ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:latest
            ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:prod
            ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:${{ steps.meta.outputs.version }}
          cache-from: type=gha
          cache-to: type=gha,mode=max

  # ─── Job 3: Deploy to Production ───────────────────────────────────────────
  deploy:
    name: Deploy to Production
    needs: build
    runs-on: ubuntu-latest
    environment: production

    steps:
      - name: Run migrations (before container swap)
        run: |
          docker run --rm \
            -e APP_ENV=production \
            -e APP_KEY=${{ secrets.PROD_APP_KEY }} \
            -e DB_HOST=${{ secrets.PROD_DB_HOST }} \
            -e DB_PORT=5432 \
            -e DB_DATABASE=${{ secrets.PROD_DB_NAME }} \
            -e DB_USERNAME=${{ secrets.PROD_DB_USER }} \
            -e DB_PASSWORD=${{ secrets.PROD_DB_PASSWORD }} \
            ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:${{ needs.build.outputs.version }} \
            php artisan migrate --force

      - name: Swap container on production server
        uses: appleboy/ssh-action@v1
        with:
          host: ${{ secrets.PROD_SSH_HOST }}
          username: ${{ secrets.PROD_SSH_USER }}
          key: ${{ secrets.PROD_SSH_KEY }}
          script: |
            docker pull ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:${{ needs.build.outputs.version }}
            docker stop app-prod || true
            docker rm app-prod || true
            docker run -d \
              --name app-prod \
              --restart unless-stopped \
              -p 80:80 \
              -e APP_ENV=production \
              -e APP_DEBUG=false \
              -e APP_KEY=${{ secrets.PROD_APP_KEY }} \
              -e DB_HOST=${{ secrets.PROD_DB_HOST }} \
              -e DB_DATABASE=${{ secrets.PROD_DB_NAME }} \
              -e DB_USERNAME=${{ secrets.PROD_DB_USER }} \
              -e DB_PASSWORD=${{ secrets.PROD_DB_PASSWORD }} \
              ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:${{ needs.build.outputs.version }}
            docker image prune -f

      - name: Create GitHub Release
        uses: softprops/action-gh-release@v2
        with:
          generate_release_notes: true
```

- [ ] **Step 2: Validate YAML syntax**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci-cd-prod.yml'))" && echo "YAML OK"
```

Expected: `YAML OK`

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ci-cd-prod.yml
git commit -m "feat: add GitHub Actions CI/CD workflow for production environment (tag-triggered)"
```

---

## GitHub Secrets Reference

### How to configure

Navigate to: `GitHub repo → Settings → Secrets and variables → Actions → New repository secret`

For environment-scoped secrets (recommended for isolation):
`Settings → Environments → development/production → Add secret`

### Required secrets per environment

**Development environment** (`Settings → Environments → development`):

| Secret | Description |
|---|---|
| `DEV_APP_KEY` | Laravel app key (`base64:...`). Generate: `php artisan key:generate --show` |
| `DEV_DB_HOST` | PostgreSQL host (managed DB hostname or IP) |
| `DEV_DB_NAME` | Database name |
| `DEV_DB_USER` | Database username |
| `DEV_DB_PASSWORD` | Database password |
| `DEV_SSH_HOST` | IP/hostname of dev server |
| `DEV_SSH_USER` | SSH user (e.g. `ubuntu`, `deploy`) |
| `DEV_SSH_KEY` | Private SSH key (PEM format, multiline OK) |

**Production environment** (`Settings → Environments → production`):

Same keys with `PROD_` prefix. Add environment protection rules:
- Require approvals before deploy
- Restrict to `main` branch / tag patterns only

**`GITHUB_TOKEN`** is automatic — no setup needed. Used for GHCR push.

### What NEVER goes in secrets

- `.env` files (use secrets individually)
- SSH known_hosts (use `appleboy/ssh-action`'s built-in)
- Docker registry passwords (use `GITHUB_TOKEN` + GHCR)
