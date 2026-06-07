# ──────────────────────────────────────────────────────────────────────────────
# CRM DLVA — environnement PREPROD.
#
# Même pattern que preprod.tf (CCPFML & co) : pas de seconde instance Postgres.
# La database preprod est créée sur l'instance DÉDIÉE dlva-db (cf. crm-dlva.tf)
# — l'isolation forte entre collectivités est conservée (les données DLVA,
# prod comme preprod, ne touchent jamais ccpfml-db), sans payer un 2e RDB.
#
# Ressources créées :
#   - 1 database `app_crm_dlva_preprod` + user `crm_dlva_app_preprod` sur dlva-db
#   - 1 namespace K8s `crm-dlva-preprod` + secret `db-credentials`
#   - 1 bucket S3 `dlva-crm-preprod` + IAM app/key + secret `media-credentials`
#   - 1 record DNS A `preprod.crm.dlva.04` → IP du LoadBalancer Ingress
#
# Secrets applicatifs (DJANGO_SECRET_KEY, MISTRAL_API_KEY…) : à créer
# manuellement, comme pour les autres namespaces preprod :
#   kubectl -n crm-dlva-preprod create secret generic crm-secrets \
#     --from-literal=DJANGO_SECRET_KEY=... \
#     --from-literal=SEED_DEFAULT_PASSWORD=... \
#     --from-literal=MISTRAL_API_KEY=...
# ──────────────────────────────────────────────────────────────────────────────

# ── Database + user preprod sur l'instance dédiée dlva-db ────────────────────

resource "random_password" "dlva_db_app_preprod" {
  length           = 32
  special          = true
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
  min_special      = 2
  override_special = "!#$%&*+-_="
}

resource "scaleway_rdb_user" "dlva_app_preprod" {
  instance_id = scaleway_rdb_instance.dlva.id
  name        = "crm_dlva_app_preprod"
  password    = random_password.dlva_db_app_preprod.result
  is_admin    = false
}

resource "scaleway_rdb_database" "dlva_app_preprod" {
  instance_id = scaleway_rdb_instance.dlva.id
  name        = "app_crm_dlva_preprod"
}

resource "scaleway_rdb_privilege" "dlva_app_preprod" {
  instance_id   = scaleway_rdb_instance.dlva.id
  database_name = scaleway_rdb_database.dlva_app_preprod.name
  user_name     = scaleway_rdb_user.dlva_app_preprod.name
  permission    = "all"

  depends_on = [scaleway_rdb_database.dlva_app_preprod, scaleway_rdb_user.dlva_app_preprod]
}

# ── Namespace K8s + secret DB ─────────────────────────────────────────────────

resource "kubernetes_namespace" "crm_dlva_preprod" {
  metadata {
    name = "crm-dlva-preprod"
    labels = {
      app         = "crm-dlva"
      environment = "preprod"
    }
  }

  depends_on = [scaleway_k8s_pool.default]
}

resource "kubernetes_secret" "crm_dlva_db_preprod" {
  metadata {
    name      = "db-credentials"
    namespace = kubernetes_namespace.crm_dlva_preprod.metadata[0].name
  }

  data = {
    DATABASE_URL = format(
      "postgres://%s:%s@%s:%d/%s?sslmode=require",
      scaleway_rdb_user.dlva_app_preprod.name,
      urlencode(random_password.dlva_db_app_preprod.result),
      scaleway_rdb_instance.dlva.private_network[0].ip,
      scaleway_rdb_instance.dlva.private_network[0].port,
      scaleway_rdb_database.dlva_app_preprod.name,
    )
  }

  type = "Opaque"
}

# ── Object Storage media DLVA preprod (même pattern que crm-dlva.tf) ─────────

resource "scaleway_object_bucket" "crm_dlva_media_preprod" {
  name       = "dlva-crm-preprod"
  project_id = var.project_id
  region     = var.scaleway_region

  versioning {
    enabled = false
  }

  cors_rule {
    allowed_methods = ["GET", "HEAD"]
    allowed_origins = ["*"]
    allowed_headers = ["*"]
    max_age_seconds = 3600
  }
}

resource "scaleway_iam_application" "crm_dlva_media_preprod" {
  name        = "crm-dlva-media-preprod"
  description = "Accès S3 au bucket dlva-crm-preprod pour le pod CRM DLVA preprod"
}

resource "scaleway_iam_policy" "crm_dlva_media_preprod" {
  application_id = scaleway_iam_application.crm_dlva_media_preprod.id
  name           = "crm-dlva-media-preprod"
  description    = "Accès Object Storage pour le pod CRM DLVA preprod (bucket cible : dlva-crm-preprod)"

  rule {
    project_ids          = [var.project_id]
    permission_set_names = ["ObjectStorageFullAccess"]
  }
}

resource "scaleway_iam_api_key" "crm_dlva_media_preprod" {
  application_id     = scaleway_iam_application.crm_dlva_media_preprod.id
  description        = "Clé API pour pod CRM DLVA preprod → dlva-crm-preprod"
  default_project_id = var.project_id
}

resource "kubernetes_secret" "crm_dlva_media_creds_preprod" {
  metadata {
    name      = "media-credentials"
    namespace = kubernetes_namespace.crm_dlva_preprod.metadata[0].name
  }

  data = {
    SCW_S3_BUCKET     = scaleway_object_bucket.crm_dlva_media_preprod.name
    SCW_S3_ENDPOINT   = "https://s3.${var.scaleway_region}.scw.cloud"
    SCW_S3_REGION     = var.scaleway_region
    SCW_S3_ACCESS_KEY = scaleway_iam_api_key.crm_dlva_media_preprod.access_key
    SCW_S3_SECRET_KEY = scaleway_iam_api_key.crm_dlva_media_preprod.secret_key
  }

  type = "Opaque"
}

# ── DNS preprod.crm.dlva.04.satkaar.io → LB Ingress ──────────────────────────

resource "ovh_domain_zone_record" "crm_dlva_04_preprod" {
  count = var.enable_dns_records ? 1 : 0

  zone      = var.ovh_zone
  subdomain = "preprod.crm.dlva.04"
  fieldtype = "A"
  ttl       = 300
  target    = local.ingress_lb_ip
}
