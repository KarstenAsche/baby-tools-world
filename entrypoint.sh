#!/bin/sh

# Docker entrypoint for the Baby Tools World Django application.
#
# Supports two runtime environments:
#   development - Runs Django's development server and applies migrations.
#   production  - Runs Gunicorn and collects static files.
#
# Additional command-line arguments bypass the default startup routine,
# allowing management commands to run inside the container.
#
# Environment variables:
#   APP_ENV  - Runtime environment (default: development).
#   APP_PORT - Application listening port (default: 8000).
#   DEBUG    - Must be set to "false" in production.
#
# Database migrations must be created during development and committed
# to version control. Production migrations are applied separately.

set -eu

if [ "$#" -gt 0 ]; then
    exec "$@"
fi

APP_ENV="${APP_ENV:-development}"
APP_PORT="${APP_PORT:-8000}"

if [ "$APP_ENV" = "production" ]; then
    echo "Starting Django in production mode..."

    if [ "${DEBUG:-false}" != "false" ]; then
        echo "ERROR: DEBUG must be false in production"
        exit 1
    fi

    python manage.py check --deploy
    python manage.py collectstatic --noinput

    exec gunicorn btw_app.wsgi:application \
        --bind "0.0.0.0:${APP_PORT}" \
        --workers 2 \
        --access-logfile - \
        --error-logfile -
else
    echo "Starting Django in development mode..."

    python manage.py migrate

    exec python manage.py runserver "0.0.0.0:${APP_PORT}"
fi
