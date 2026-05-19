#!/usr/bin/env bash
# Build et push l'image Docker d'une app vers le Container Registry Scaleway.
# Usage : ./build-and-push.sh <app> [tag]
# Exemple : ./build-and-push.sh entreprise v1.0.0
set -euo pipefail

if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <app> [tag]"
    echo "Apps : entreprise, ecole, creche, association, document-citoyen, crm-mairie-agglo"
    exit 1
fi

APP="$1"
TAG="${2:-latest}"
REGISTRY="rg.fr-par.scw.cloud/mairie-agglo-platform"
IMAGE="$REGISTRY/$APP:$TAG"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_DIR="$ROOT/$APP"

if [ ! -d "$APP_DIR" ]; then
    echo "✗ App directory '$APP_DIR' introuvable."
    exit 1
fi

# Map app → wsgi module Python (dossier interne du projet Django).
case "$APP" in
    entreprise|ecole|creche|association)
        WSGI_MODULE="${APP}.wsgi"
        ;;
    document-citoyen)
        WSGI_MODULE="document_citoyen.wsgi"
        ;;
    crm-mairie-agglo)
        WSGI_MODULE="crm_mairie_agglo.wsgi"
        ;;
    *)
        echo "✗ App '$APP' inconnue."
        exit 1
        ;;
esac

echo "==> Build $IMAGE (WSGI=$WSGI_MODULE)"
cd "$APP_DIR"
docker build \
    --platform linux/amd64 \
    --build-arg "DJANGO_WSGI_MODULE=$WSGI_MODULE" \
    -t "$IMAGE" \
    .

echo "==> Push $IMAGE"
docker push "$IMAGE"

echo "✓ $IMAGE pushed"
