# ──────────────────────────────────────────────────────────────────────────────
# Environnement PREPROD — déployé sur le MÊME cluster Kapsule et le MÊME
# Postgres mutualisé que la prod (isolation par namespace + database
# distinctes). Pattern volontaire pour minimiser les coûts : pas de second
# cluster, pas de second RDB. Risque accepté : un mauvais helm upgrade sur le
# cluster reste un soucis cross-env, mais l'isolation logique (namespaces +
# RBAC + DB séparées + creds séparés) couvre 95% des cas pratiques.
#
# Ressources créées par app preprod :
#   - 1 database `<app_db>_preprod` sur la même instance RDB
#   - 1 user `<app_db_user>_preprod` avec mdp distinct
#   - 1 privilege `all` sur sa propre DB
#   - 1 namespace K8s `<app>-preprod`
#   - 1 secret `db-credentials` dans ce namespace
#   - 1 record DNS A `preprod.<subdomain>` → IP du LoadBalancer Ingress
#
# Les secrets applicatifs (DJANGO_SECRET_KEY, KATARINA_CRM_TOKEN, MISTRAL,
# SMTP, etc.) sont à créer manuellement dans le namespace `<app>-preprod`,
# avec leurs propres valeurs preprod. Cf. scripts/sync-app-secrets.sh ou
# platform/README.md.

locals {
  # Mêmes apps que prod (cf. main.tf locals.apps) mais avec suffixes preprod.
  # Réutilise les champs de local.apps via une transformation.
  apps_preprod = {
    for k, v in local.apps : k => merge(v, {
      db_name = "${v.db_name}_preprod"
      db_user = "${v.db_user}_preprod"
    })
  }
}

resource "random_password" "db_app_preprod" {
  for_each = local.apps_preprod

  length           = 32
  special          = true
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
  min_special      = 2
  override_special = "!#$%&*+-_="
}

resource "scaleway_rdb_user" "app_preprod" {
  for_each = local.apps_preprod

  instance_id = scaleway_rdb_instance.shared.id
  name        = each.value.db_user
  password    = random_password.db_app_preprod[each.key].result
  is_admin    = false
}

resource "scaleway_rdb_database" "app_preprod" {
  for_each = local.apps_preprod

  instance_id = scaleway_rdb_instance.shared.id
  name        = each.value.db_name
}

resource "scaleway_rdb_privilege" "app_preprod" {
  for_each = local.apps_preprod

  instance_id   = scaleway_rdb_instance.shared.id
  database_name = scaleway_rdb_database.app_preprod[each.key].name
  user_name     = scaleway_rdb_user.app_preprod[each.key].name
  permission    = "all"

  depends_on = [scaleway_rdb_database.app_preprod, scaleway_rdb_user.app_preprod]
}

resource "kubernetes_namespace" "app_preprod" {
  for_each = local.apps_preprod

  metadata {
    name = "${each.key}-preprod"
    labels = {
      app         = each.key
      environment = "preprod"
    }
  }

  depends_on = [scaleway_k8s_pool.default]
}

resource "kubernetes_secret" "db_preprod" {
  for_each = local.apps_preprod

  metadata {
    name      = "db-credentials"
    namespace = kubernetes_namespace.app_preprod[each.key].metadata[0].name
  }

  data = {
    DATABASE_URL = format(
      "postgres://%s:%s@%s:%d/%s?sslmode=require",
      scaleway_rdb_user.app_preprod[each.key].name,
      urlencode(random_password.db_app_preprod[each.key].result),
      scaleway_rdb_instance.shared.endpoint_ip,
      scaleway_rdb_instance.shared.endpoint_port,
      scaleway_rdb_database.app_preprod[each.key].name,
    )
  }

  type = "Opaque"
}

# Record DNS preprod (sous-domaine preprod.<sub>.satkaar.io) — créé seulement
# si enable_dns_records=true, comme pour la prod (cf. main.tf).
resource "ovh_domain_zone_record" "app_preprod" {
  for_each = var.enable_dns_records ? local.apps_preprod : {}

  zone      = var.ovh_zone
  subdomain = "preprod.${each.value.subdomain}"
  fieldtype = "A"
  ttl       = 300
  target    = local.ingress_lb_ip
}
