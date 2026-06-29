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
    && chown -R www-data:www-data storage bootstrap/cache

EXPOSE 80

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisord.conf"]
