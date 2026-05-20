#!/usr/bin/env bash
# Migre une ancienne Postgres Scaleway (Serverless Containers era) vers une base
# de la Postgres mutualisée Kapsule.
#
# Deux modes selon que la cible a déjà un schéma applicatif ou non :
#
# - mode=data-only :
#     • La cible a déjà ses migrations Django appliquées (pods Kapsule tournent).
#     • On TRUNCATE les tables applicatives (préserve django_migrations,
#       django_content_type, auth_permission qui sont gérés par Django).
#     • pg_dump --data-only puis pg_restore --data-only --disable-triggers.
#     • Permet d'écraser les seeds de l'entrypoint Kapsule par la vraie data.
#
# - mode=full :
#     • La cible est vide (aucun pod Kapsule n'a tourné dessus, pas de schéma).
#     • pg_dump complet (schema+data) puis pg_restore --no-owner --no-acl.
#
# Usage :
#   migrate-postgres-to-postgres.sh <mode> <source_url_file> <target_url_file> [exclude_pattern]
#
# Exemple :
#   migrate-postgres-to-postgres.sh data-only /tmp/_crm_prod_url /tmp/_new_crm_prod_url 'sso_*'
#   migrate-postgres-to-postgres.sh full      /tmp/_crm_pre_url  /tmp/_new_crm_pre_url  'sso_*'
#   migrate-postgres-to-postgres.sh full      /tmp/_doc_pre_url  /tmp/_new_doc_pre_url

set -euo pipefail

if [ "$#" -lt 3 ]; then
    echo "Usage: $0 <mode> <source_url_file> <target_url_file> [exclude_pattern]"
    echo "  mode: data-only | full"
    exit 1
fi

MODE="$1"
SOURCE_URL="$(cat "$2")"
TARGET_URL="$(cat "$3")"
EXCLUDE_PATTERN="${4:-}"

if [ -z "$SOURCE_URL" ] || [ -z "$TARGET_URL" ]; then
    echo "✗ URL source ou cible vide"
    exit 1
fi

DUMP_FILE="/tmp/migrate-$(basename "$2")-to-$(basename "$3")-$(date +%H%M%S).dump"

# Ping rapide
echo "==> Ping source..."
psql "$SOURCE_URL" -tA -c "SELECT 1;" > /dev/null || { echo "✗ source injoignable"; exit 1; }
echo "==> Ping cible..."
psql "$TARGET_URL" -tA -c "SELECT 1;" > /dev/null || { echo "✗ cible injoignable"; exit 1; }

# Construction des flags pg_dump
DUMP_FLAGS=(-Fc --no-owner --no-acl)
case "$MODE" in
    data-only)
        DUMP_FLAGS+=(--data-only)
        # On exclut aussi django_content_type et auth_permission : Django les gère
        # via les post-migrate signals, ils ont déjà été peuplés à l'identique côté
        # cible. Restaurer crée des collisions ID.
        DUMP_FLAGS+=(--exclude-table=django_content_type --exclude-table=auth_permission --exclude-table=django_migrations)
        ;;
    full)
        ;;
    *)
        echo "✗ mode inconnu : $MODE (attendu : data-only | full)"; exit 1
        ;;
esac

if [ -n "$EXCLUDE_PATTERN" ]; then
    DUMP_FLAGS+=(--exclude-table="$EXCLUDE_PATTERN")
fi

echo "==> pg_dump (mode=$MODE) → $DUMP_FILE"
echo "    pg_dump ${DUMP_FLAGS[*]}"
pg_dump "${DUMP_FLAGS[@]}" "$SOURCE_URL" -f "$DUMP_FILE"
DUMP_SIZE=$(wc -c < "$DUMP_FILE")
echo "    $DUMP_FILE ($DUMP_SIZE bytes)"

if [ "$MODE" = "data-only" ]; then
    echo "==> TRUNCATE des tables applicatives de la cible..."
    psql "$TARGET_URL" -v ON_ERROR_STOP=1 <<'EOSQL'
DO $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
      SELECT tablename FROM pg_tables
      WHERE schemaname='public'
        AND tablename NOT IN ('django_migrations','django_content_type','auth_permission')
  LOOP
    EXECUTE 'TRUNCATE TABLE public.' || quote_ident(r.tablename) || ' RESTART IDENTITY CASCADE';
  END LOOP;
END$$;
EOSQL
fi

# Construction des flags pg_restore (par défaut PAS de --clean : on ne drop
# rien côté cible — TRUNCATE en amont en mode data-only, cible vide en full).
RESTORE_FLAGS=(--no-owner --no-acl --disable-triggers)
if [ "$MODE" = "data-only" ]; then
    RESTORE_FLAGS+=(--data-only)
fi

echo "==> pg_restore..."
echo "    pg_restore ${RESTORE_FLAGS[*]}"
# `--single-transaction` impossible avec --disable-triggers (qui demande superuser
# sans single-tx, mais le user app sera privilégié sur ses tables). En cas
# d'erreur, on peut relancer puisqu'on a TRUNCATE en amont.
pg_restore "${RESTORE_FLAGS[@]}" -d "$TARGET_URL" "$DUMP_FILE" 2>&1 | tail -30 || {
    echo "⚠ pg_restore a remonté des erreurs (normal pour des FK ou tables manquantes — vérifier ci-dessus)"
}

echo "✓ Migration terminée"
echo "  Dump conservé : $DUMP_FILE"
