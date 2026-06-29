#!/bin/sh
set -e

# Only warm caches when starting the server, not for one-shot artisan commands
if [ "$1" != "php" ]; then
    php artisan config:cache
    php artisan route:cache
    php artisan view:cache
fi

if [ "$RUN_MIGRATIONS" = "true" ]; then
    echo "Running migrations..."
    php artisan migrate --force
fi

exec "$@"
