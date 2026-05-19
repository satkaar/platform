#!/usr/bin/env bash
# Migre les données SQLite d'une app vers la base Postgres mutualisée.
# Le DATABASE_URL Postgres est récupéré depuis le secret K8s créé par Terraform.
#
# Usage : ./migrate-sqlite-to-postgres.sh <app>
# Prérequis : Python venv local de l'app avec deps installées + KUBECONFIG défini.
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <app>"
    echo "Apps : entreprise, ecole, creche, association"
    echo "  (CRM et document-citoyen migrent leur Postgres existante via pg_dump séparément)"
    exit 1
fi

APP="$1"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_DIR="$ROOT/$APP"
DUMP_FILE="/tmp/dump-$APP-$(date +%Y%m%d-%H%M%S).json"

if [ ! -d "$APP_DIR" ]; then
    echo "✗ App directory '$APP_DIR' introuvable."
    exit 1
fi

if [ ! -f "$APP_DIR/db.sqlite3" ]; then
    echo "⚠ Pas de db.sqlite3 dans $APP_DIR — rien à migrer."
    exit 0
fi

# Récupère le DATABASE_URL depuis le secret K8s
echo "==> Récupération du DATABASE_URL depuis K8s (namespace: $APP)..."
DATABASE_URL=$(kubectl -n "$APP" get secret db-credentials \
    -o jsonpath='{.data.DATABASE_URL}' | base64 -d)

if [ -z "$DATABASE_URL" ]; then
    echo "✗ Secret db-credentials introuvable ou vide dans le namespace $APP."
    echo "  Vérifier que terraform apply a été exécuté."
    exit 1
fi

cd "$APP_DIR"

# 1. Dump SQLite (sans DATABASE_URL → utilise SQLite local)
echo "==> Dump des données SQLite → $DUMP_FILE"
unset DATABASE_URL
python manage.py dumpdata \
    --natural-foreign --natural-primary \
    --exclude contenttypes --exclude auth.permission \
    --indent 2 \
    > "$DUMP_FILE"

DUMP_SIZE=$(wc -c < "$DUMP_FILE")
echo "   $DUMP_FILE ($DUMP_SIZE bytes)"

# 2. Re-récupère le DATABASE_URL et applique les migrations + load des données
export DATABASE_URL=$(kubectl -n "$APP" get secret db-credentials \
    -o jsonpath='{.data.DATABASE_URL}' | base64 -d)

echo "==> Migrations Django sur la Postgres mutualisée..."
python manage.py migrate --noinput

echo "==> Loaddata depuis $DUMP_FILE..."
python manage.py loaddata "$DUMP_FILE"

echo "✓ Migration $APP : SQLite → Postgres OK"
echo "  Vérifier en se connectant à l'admin Django de la version K8s."
