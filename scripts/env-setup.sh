#!/bin/sh
# Source ce fichier avant tout `make` ou `terraform` :
#   source platform/scripts/env-setup.sh
#
# Exporte :
# - AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY : backend S3 Terraform (Scaleway S3-compat)
# - TF_VAR_scaleway_organization_id : variable Terraform homonyme
# - OVH_ENDPOINT / OVH_APPLICATION_KEY / OVH_APPLICATION_SECRET / OVH_CONSUMER_KEY
#   pour le provider Terraform OVH (records DNS satkaar.io)

SCW_CONF="${HOME}/.config/scw/config.yaml"
if [ ! -f "$SCW_CONF" ]; then
    echo "✗ ~/.config/scw/config.yaml introuvable. Configurer scw avec 'scw init'."
    return 1 2>/dev/null || exit 1
fi

export AWS_ACCESS_KEY_ID=$(awk -F': ' '/^access_key:/ {print $2}' "$SCW_CONF")
export AWS_SECRET_ACCESS_KEY=$(awk -F': ' '/^secret_key:/ {print $2}' "$SCW_CONF")
export TF_VAR_scaleway_organization_id=$(awk -F': ' '/^default_organization_id:/ {print $2}' "$SCW_CONF")

# Credentials OVH : mutualisés avec le repo Satkar (provider OVH même orga).
# Le .env contient TF_VAR_ovh_* — on les remappe vers OVH_* pour le provider.
OVH_ENV_FILE="/Users/damienmarque/mairie-agglo/Satkar/satkaar-site/script/.env"
if [ -f "$OVH_ENV_FILE" ]; then
    # shellcheck disable=SC2046
    export $(grep -E "^TF_VAR_ovh_" "$OVH_ENV_FILE" | xargs)
    export OVH_ENDPOINT="${TF_VAR_ovh_endpoint:-ovh-eu}"
    export OVH_APPLICATION_KEY="$TF_VAR_ovh_application_key"
    export OVH_APPLICATION_SECRET="$TF_VAR_ovh_application_secret"
    export OVH_CONSUMER_KEY="$TF_VAR_ovh_consumer_key"
fi

echo "✓ env Scaleway exportées (orga: ${TF_VAR_scaleway_organization_id})"
if [ -n "$OVH_APPLICATION_KEY" ]; then
    echo "✓ env OVH exportées (endpoint: ${OVH_ENDPOINT})"
else
    echo "⚠ pas de credentials OVH (records DNS échoueront)"
fi
