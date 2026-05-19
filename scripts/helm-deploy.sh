#!/usr/bin/env bash
# Déploie une release Helm sur Kapsule.
# Usage : ./helm-deploy.sh <release> [tag] [--namespace <ns>]
#
# Par défaut, namespace = nom de release. Override utile pour les runners qui
# doivent partager les secrets de l'app web (ex: crm-mairie-agglo-runner →
# namespace crm-mairie-agglo).
#
# Exemples :
#   ./helm-deploy.sh entreprise v1.0.0
#   ./helm-deploy.sh crm-mairie-agglo v1.0.0
#   ./helm-deploy.sh crm-mairie-agglo-runner v1.0.0 --namespace crm-mairie-agglo
set -euo pipefail

if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <release> [tag] [--namespace <ns>]"
    exit 1
fi

RELEASE="$1"
shift

TAG="latest"
NAMESPACE="$RELEASE"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        --namespace=*)
            NAMESPACE="${1#--namespace=}"
            shift
            ;;
        *)
            TAG="$1"
            shift
            ;;
    esac
done

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHART="$ROOT/platform/helm/django-app"
VALUES="$ROOT/platform/helm/values/$RELEASE.yaml"

if [ ! -f "$VALUES" ]; then
    echo "✗ Values file '$VALUES' introuvable."
    exit 1
fi

if [ -z "${KUBECONFIG:-}" ]; then
    echo "⚠ KUBECONFIG non défini. Tente le kubeconfig courant kubectl."
fi

echo "==> helm upgrade --install $RELEASE (ns=$NAMESPACE, image tag=$TAG)"
helm upgrade --install "$RELEASE" "$CHART" \
    --namespace "$NAMESPACE" \
    --create-namespace \
    --values "$VALUES" \
    --set "image.tag=$TAG" \
    --wait \
    --timeout 5m

echo "✓ $RELEASE deployed (ns=$NAMESPACE)"
echo ""
echo "Vérifier :"
echo "  kubectl -n $NAMESPACE get pods,svc,ingress -l app.kubernetes.io/instance=$RELEASE"
echo "  kubectl -n $NAMESPACE logs -l app.kubernetes.io/instance=$RELEASE --tail=50"
