#!/usr/bin/env bash
# Installe le Dockerfile et l'entrypoint génériques dans une app simple.
# Usage : ./install-dockerfile.sh <app-name>
# Exemple : ./install-dockerfile.sh entreprise
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <app-name>"
    echo "Apps simples : entreprise, ecole, creche, association"
    exit 1
fi

APP="$1"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_DIR="$ROOT/$APP"

if [ ! -d "$APP_DIR" ]; then
    echo "✗ App directory '$APP_DIR' introuvable."
    exit 1
fi

cp "$ROOT/platform/dockerfiles/Dockerfile.django-simple" "$APP_DIR/Dockerfile"
cp "$ROOT/platform/dockerfiles/entrypoint-simple.sh" "$APP_DIR/entrypoint.sh"
chmod +x "$APP_DIR/entrypoint.sh"

echo "✓ Dockerfile + entrypoint.sh copiés dans $APP_DIR"
echo "  WSGI module à passer au build : --build-arg DJANGO_WSGI_MODULE=$APP.wsgi"
