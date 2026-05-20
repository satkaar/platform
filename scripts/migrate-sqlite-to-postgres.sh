#!/usr/bin/env bash
# Migre les données SQLite d'une app vers la base Postgres mutualisée.
#
# Stratégie :
# 1. dumpdata depuis SQLite (en local, venv .venv de l'app — juste Django requis)
# 2. copie le dump dans le pod web via `kubectl exec -i`
# 3. `flush --no-input` côté pod pour vider la Postgres (les seeds entrypoint
#    sont remplacés par le contenu SQLite — décision utilisateur)
# 4. `loaddata` côté pod (psycopg + dj-database-url déjà installés dans l'image)
#
# Usage : ./migrate-sqlite-to-postgres.sh <app>
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <app>"
    echo "Apps : entreprise, ecole, creche, association"
    echo "  (CRM et document-citoyen migrent via pg_dump séparément)"
    exit 1
fi

APP="$1"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_DIR="$ROOT/$APP"
DUMP_FILE="/tmp/dump-$APP-$(date +%Y%m%d-%H%M%S).json"
VENV_PY="$APP_DIR/.venv/bin/python"

if [ ! -d "$APP_DIR" ]; then
    echo "✗ App directory '$APP_DIR' introuvable."
    exit 1
fi

if [ ! -f "$APP_DIR/db.sqlite3" ]; then
    echo "⚠ Pas de db.sqlite3 dans $APP_DIR — rien à migrer."
    exit 0
fi

if [ ! -x "$VENV_PY" ]; then
    echo "✗ Venv Python introuvable : $VENV_PY"
    exit 1
fi

# Récupère un pod web Running pour exécuter flush + loaddata
POD=$(kubectl -n "$APP" get pod \
    -l "app.kubernetes.io/name=$APP" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}')

if [ -z "$POD" ]; then
    echo "✗ Aucun pod Running pour app=$APP dans namespace $APP."
    exit 1
fi
echo "==> Pod cible : $POD"

# 1. Dump SQLite en local (venv n'a besoin que de Django)
cd "$APP_DIR"
echo "==> Dump SQLite → $DUMP_FILE"
unset DATABASE_URL  # force la default SQLite
"$VENV_PY" manage.py dumpdata \
    --natural-foreign --natural-primary \
    --exclude contenttypes \
    --exclude auth.permission \
    --exclude admin.logentry \
    --exclude sessions.session \
    --indent 2 \
    > "$DUMP_FILE"

DUMP_SIZE=$(wc -c < "$DUMP_FILE")
echo "   $DUMP_FILE ($DUMP_SIZE bytes)"

# 2. Flush Postgres dans le pod (vide TOUTES les tables sauf django_migrations)
echo "==> Flush Postgres côté pod..."
kubectl -n "$APP" exec "$POD" -- python manage.py flush --no-input

# 3. Loaddata : on pipe le dump local dans le pod (pas de kubectl cp qui exige tar)
echo "==> Loaddata depuis $DUMP_FILE..."
kubectl -n "$APP" exec -i "$POD" -- sh -c 'cat > /tmp/dump.json' < "$DUMP_FILE"
kubectl -n "$APP" exec "$POD" -- python manage.py loaddata /tmp/dump.json
kubectl -n "$APP" exec "$POD" -- rm -f /tmp/dump.json

echo "✓ Migration $APP : SQLite → Postgres OK"
