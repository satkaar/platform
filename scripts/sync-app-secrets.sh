#!/bin/bash
# Synchronise les secrets applicatifs K8s à partir des .env locaux des apps :
# - crm-mairie-agglo/.env       → secret crm-secrets + crm-telegram-secrets
# - document-citoyen/.env       → secret document-citoyen-secrets
#
# Préserve DJANGO_SECRET_KEY déjà présent dans les secrets K8s (pour ne pas
# invalider les sessions/objets signés). Surcharge KATARINA_BASE_URL et
# KATARINA_CRM_API_URL avec les bonnes URLs (interne K8s ou public satkaar.io).
#
# Usage : ./platform/scripts/sync-app-secrets.sh
#
# Prérequis :
# - source platform/scripts/env-setup.sh
# - kubectl + scw CLI installés
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

. "$ROOT/platform/scripts/env-setup.sh" > /dev/null

# Récupération dynamique de l'ID du cluster Kapsule
CLUSTER_NAME="${CLUSTER_NAME:-mairie-agglo-prod}"
CLUSTER_ID=$(scw k8s cluster list region=fr-par -o json 2>/dev/null \
    | python3 -c "import json, sys; d=json.load(sys.stdin); print(next((c['id'] for c in d if c['name'] == '$CLUSTER_NAME'), ''))")

if [ -z "$CLUSTER_ID" ]; then
    echo "✗ Cluster '$CLUSTER_NAME' introuvable dans fr-par."
    exit 1
fi

TMPKUBE=$(mktemp)
trap "rm -f $TMPKUBE" EXIT
scw k8s kubeconfig get "$CLUSTER_ID" > "$TMPKUBE" 2>&1
export KUBECONFIG="$TMPKUBE"

CRM_ENV="$ROOT/crm-mairie-agglo/.env"
DOC_ENV="$ROOT/document-citoyen/.env"

# Extrait la valeur d'une clé depuis un .env (strip quotes + espaces)
env_val() {
    local key="$1" file="$2"
    awk -F'=' -v k="$key" '
        $1 == k {
            v = substr($0, length(k)+2)
            sub(/^[[:space:]]+/, "", v)
            sub(/[[:space:]]+$/, "", v)
            gsub(/^["'\'']|["'\'']$/, "", v)
            print v
            exit
        }
    ' "$file"
}

# ───────────────────────── CRM ─────────────────────────
echo "=== Lecture des valeurs CRM depuis $CRM_ENV ==="
[ -f "$CRM_ENV" ] || { echo "✗ $CRM_ENV introuvable"; exit 1; }

DJANGO_KEY=$(kubectl -n crm-mairie-agglo get secret crm-secrets -o jsonpath='{.data.DJANGO_SECRET_KEY}' | base64 -d)
MISTRAL=$(env_val MISTRAL_API_KEY "$CRM_ENV")
MISTRAL_MODEL=$(env_val MISTRAL_MODEL "$CRM_ENV")
KATARINA_TOKEN=$(env_val KATARINA_CRM_TOKEN "$CRM_ENV")
WEBHOOK_SECRET=$(env_val CRM_WEBHOOK_SECRET "$CRM_ENV")
EMAIL_HOST=$(env_val EMAIL_HOST "$CRM_ENV")
EMAIL_PORT=$(env_val EMAIL_PORT "$CRM_ENV")
EMAIL_USE_TLS=$(env_val EMAIL_USE_TLS "$CRM_ENV")
EMAIL_USERNAME=$(env_val EMAIL_USERNAME "$CRM_ENV")
EMAIL_PASSWORD=$(env_val EMAIL_PASSWORD "$CRM_ENV")
EMAIL_FROM=$(env_val EMAIL_FROM "$CRM_ENV")
SEED_DEFAULT_PASSWORD=$(env_val SEED_DEFAULT_PASSWORD "$CRM_ENV")
TG_API_ID=$(env_val TELEGRAM_API_ID "$CRM_ENV")
TG_API_HASH=$(env_val TELEGRAM_API_HASH "$CRM_ENV")
TG_FERNET=$(env_val TELEGRAM_FERNET_KEY "$CRM_ENV")

for v in MISTRAL KATARINA_TOKEN WEBHOOK_SECRET EMAIL_USERNAME EMAIL_PASSWORD; do
    if [ -z "${!v:-}" ]; then
        echo "✗ $v vide dans $CRM_ENV. Abort."
        exit 1
    fi
done

echo "  ✓ valeurs CRM extraites"
echo
echo "=== Recréation crm-secrets ==="
kubectl -n crm-mairie-agglo create secret generic crm-secrets \
    --from-literal=DJANGO_SECRET_KEY="$DJANGO_KEY" \
    --from-literal=MISTRAL_API_KEY="$MISTRAL" \
    --from-literal=MISTRAL_MODEL="${MISTRAL_MODEL:-mistral-small-latest}" \
    --from-literal=KATARINA_CRM_TOKEN="$KATARINA_TOKEN" \
    --from-literal=CRM_WEBHOOK_SECRET="$WEBHOOK_SECRET" \
    --from-literal=KATARINA_BASE_URL="https://documents.satkaar.io" \
    --from-literal=EMAIL_HOST="$EMAIL_HOST" \
    --from-literal=EMAIL_PORT="${EMAIL_PORT:-587}" \
    --from-literal=EMAIL_USE_TLS="${EMAIL_USE_TLS:-True}" \
    --from-literal=EMAIL_USERNAME="$EMAIL_USERNAME" \
    --from-literal=EMAIL_PASSWORD="$EMAIL_PASSWORD" \
    --from-literal=EMAIL_FROM="$EMAIL_FROM" \
    --from-literal=DEFAULT_FROM_EMAIL="$EMAIL_FROM" \
    --from-literal=SEED_DEFAULT_PASSWORD="${SEED_DEFAULT_PASSWORD:-}" \
    --dry-run=client -o yaml | kubectl apply -f - | tail -2

# Bonus : crm-telegram-secrets si les creds Telegram sont là
if [ -n "$TG_API_ID" ] && [ -n "$TG_API_HASH" ] && [ -n "$TG_FERNET" ]; then
    echo
    echo "=== Création/maj crm-telegram-secrets (runner) ==="
    kubectl -n crm-mairie-agglo create secret generic crm-telegram-secrets \
        --from-literal=TELEGRAM_API_ID="$TG_API_ID" \
        --from-literal=TELEGRAM_API_HASH="$TG_API_HASH" \
        --from-literal=TELEGRAM_FERNET_KEY="$TG_FERNET" \
        --dry-run=client -o yaml | kubectl apply -f - | tail -2
fi

# ───────────────── document-citoyen ─────────────────
echo
echo "=== Lecture des valeurs document-citoyen depuis $DOC_ENV ==="
[ -f "$DOC_ENV" ] || { echo "✗ $DOC_ENV introuvable"; exit 1; }

DOC_DJANGO_KEY=$(kubectl -n document-citoyen get secret document-citoyen-secrets -o jsonpath='{.data.DJANGO_SECRET_KEY}' | base64 -d)
DOC_EMAIL_HOST=$(env_val EMAIL_HOST "$DOC_ENV")
DOC_EMAIL_PORT=$(env_val EMAIL_PORT "$DOC_ENV")
DOC_EMAIL_USER=$(env_val EMAIL_USERNAME "$DOC_ENV")
DOC_EMAIL_PWD=$(env_val EMAIL_PASSWORD "$DOC_ENV")
DOC_EMAIL_FROM=$(env_val EMAIL_FROM "$DOC_ENV")
DOC_DEFAULT_FROM=$(env_val DJANGO_DEFAULT_FROM_EMAIL "$DOC_ENV")
DOC_KATARINA_TOKEN=$(env_val KATARINA_CRM_TOKEN "$DOC_ENV")
DOC_WEBHOOK_SECRET=$(env_val CRM_WEBHOOK_SECRET "$DOC_ENV")

for v in DOC_EMAIL_USER DOC_EMAIL_PWD DOC_KATARINA_TOKEN; do
    if [ -z "${!v:-}" ]; then
        echo "✗ $v vide dans $DOC_ENV. Abort."
        exit 1
    fi
done

# Vérif cohérence inter-app
if [ "$KATARINA_TOKEN" != "$DOC_KATARINA_TOKEN" ]; then
    echo "⚠ KATARINA_CRM_TOKEN diffère entre CRM (.env) et document-citoyen (.env)."
fi
if [ "$WEBHOOK_SECRET" != "$DOC_WEBHOOK_SECRET" ]; then
    echo "⚠ CRM_WEBHOOK_SECRET diffère entre CRM (.env) et document-citoyen (.env)."
fi

echo "  ✓ valeurs document-citoyen extraites"
echo
echo "=== Recréation document-citoyen-secrets ==="
echo "  Note : AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY non présentes dans le .env"
echo "         (à compléter manuellement si on veut activer les uploads S3 Scaleway)"
echo
kubectl -n document-citoyen create secret generic document-citoyen-secrets \
    --from-literal=DJANGO_SECRET_KEY="$DOC_DJANGO_KEY" \
    --from-literal=KATARINA_CRM_TOKEN="$DOC_KATARINA_TOKEN" \
    --from-literal=CRM_WEBHOOK_SECRET="$DOC_WEBHOOK_SECRET" \
    --from-literal=KATARINA_CRM_API_URL="http://crm-mairie-agglo.crm-mairie-agglo.svc.cluster.local" \
    --from-literal=PUBLIC_BASE_URL="https://documents.satkaar.io" \
    --from-literal=EMAIL_HOST="$DOC_EMAIL_HOST" \
    --from-literal=EMAIL_PORT="${DOC_EMAIL_PORT:-587}" \
    --from-literal=EMAIL_USERNAME="$DOC_EMAIL_USER" \
    --from-literal=EMAIL_PASSWORD="$DOC_EMAIL_PWD" \
    --from-literal=EMAIL_FROM="$DOC_EMAIL_FROM" \
    --from-literal=DJANGO_DEFAULT_FROM_EMAIL="${DOC_DEFAULT_FROM:-$DOC_EMAIL_FROM}" \
    --dry-run=client -o yaml | kubectl apply -f - | tail -2

echo
echo "=== Rolling restart des pods (pour relire les secrets) ==="
kubectl -n crm-mairie-agglo rollout restart deployment/crm-mairie-agglo 2>&1 | tail -1
kubectl -n document-citoyen rollout restart deployment/document-citoyen 2>&1 | tail -1
# Restart aussi le runner si il consomme crm-telegram-secrets
if kubectl -n crm-mairie-agglo get deployment crm-runner > /dev/null 2>&1; then
    kubectl -n crm-mairie-agglo rollout restart deployment/crm-runner 2>&1 | tail -1
fi

echo
echo "=== Attente Ready ==="
kubectl -n crm-mairie-agglo rollout status deployment/crm-mairie-agglo --timeout=2m 2>&1 | tail -1
kubectl -n document-citoyen rollout status deployment/document-citoyen --timeout=2m 2>&1 | tail -1
if kubectl -n crm-mairie-agglo get deployment crm-runner > /dev/null 2>&1; then
    kubectl -n crm-mairie-agglo rollout status deployment/crm-runner --timeout=2m 2>&1 | tail -1
fi

echo
echo "✓ Secrets synchronisés et pods reroutés."
