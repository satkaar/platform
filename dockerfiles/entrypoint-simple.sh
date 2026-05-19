#!/bin/sh
# Entrypoint pour les apps Django simples (entreprise, ecole, creche,
# association). Migrations + collectstatic + gunicorn. DJANGO_WSGI_MODULE
# est défini comme ARG dans le Dockerfile.
set -e

echo "==> Collecting static files..."
python manage.py collectstatic --noinput

echo "==> Running migrations..."
python manage.py migrate --noinput

if [ -n "${DJANGO_SUPERUSER_USERNAME}" ] && [ -n "${DJANGO_SUPERUSER_PASSWORD}" ]; then
    echo "==> Creating superuser '${DJANGO_SUPERUSER_USERNAME}'..."
    python manage.py createsuperuser --noinput \
        --username "${DJANGO_SUPERUSER_USERNAME}" \
        --email "${DJANGO_SUPERUSER_EMAIL:-admin@example.com}" \
        2>/dev/null && echo "   Superuser created." || echo "   Superuser already exists, skipping."
fi

echo "==> Starting Gunicorn ($DJANGO_WSGI_MODULE) on port ${PORT:-8080}..."
exec gunicorn "${DJANGO_WSGI_MODULE}:application" \
    --bind "0.0.0.0:${PORT:-8080}" \
    --workers "${GUNICORN_WORKERS:-2}" \
    --timeout 120 \
    --log-level info \
    --access-logfile - \
    --error-logfile -
