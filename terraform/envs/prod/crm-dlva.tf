# ──────────────────────────────────────────────────────────────────────────────
# CRM DLVA — 2e déploiement du CRM mairie/agglo (Durance-Luberon-Verdon
# Agglomération) depuis le MÊME repo source (satkaar/crm-mairie).
#
# Multi-déploiement mono-repo : le code choisit son référentiel territorial
# via la variable d'environnement COLLECTIVITE=dlva (cf. referentiels/ dans le
# repo crm). Côté infra, la DLVA a son propre namespace K8s `crm-dlva`, sa
# propre instance Postgres DÉDIÉE (isolation forte des données entre
# collectivités), son bucket S3 media, et son host crm.dlva.04.satkaar.io.
#
# Conventions du workflow réutilisable (reusable-deploy.yml) :
#   app-name = "crm-dlva" → namespace = crm-dlva, values = crm-dlva.yaml,
#   image = rg.fr-par.scw.cloud/mairie-agglo-platform/crm-dlva.
#
# Secrets applicatifs (DJANGO_SECRET_KEY, MISTRAL_API_KEY…) : comme pour
# CCPFML, créés manuellement (pattern crm-secrets) :
#   kubectl -n crm-dlva create secret generic crm-secrets \
#     --from-literal=DJANGO_SECRET_KEY=... \
#     --from-literal=SEED_DEFAULT_PASSWORD=... \
#     --from-literal=MISTRAL_API_KEY=...
# ──────────────────────────────────────────────────────────────────────────────

# ── Postgres DÉDIÉE DLVA (isolation forte vs instance mutualisée ccpfml-db) ──

variable "dlva_postgres_node_type" {
  description = "Type de nœud Postgres pour l'instance dédiée DLVA."
  type        = string
  default     = "DB-DEV-S"
}

variable "dlva_postgres_volume_size_gb" {
  description = "Taille du volume Postgres DLVA (Go)."
  type        = number
  default     = 10
}

resource "random_password" "dlva_db_admin" {
  length           = 32
  special          = true
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
  min_special      = 2
  override_special = "!#$%&*+-_="
}

resource "scaleway_rdb_instance" "dlva" {
  name                      = "dlva-db"
  project_id                = var.project_id
  region                    = var.scaleway_region
  node_type                 = var.dlva_postgres_node_type
  engine                    = "PostgreSQL-16"
  user_name                 = "dlva_admin"
  password                  = random_password.dlva_db_admin.result
  volume_size_in_gb         = var.dlva_postgres_volume_size_gb
  volume_type               = "sbs_5k"
  disable_backup            = false
  backup_schedule_frequency = 24
  backup_schedule_retention = 7

  # Endpoint privé sur le même VPC que Kapsule — les pods accèdent à
  # Postgres sans passer par Internet (même pattern que ccpfml-db).
  private_network {
    pn_id       = scaleway_vpc_private_network.this.id
    enable_ipam = true
  }
}

resource "random_password" "dlva_db_app" {
  length           = 32
  special          = true
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
  min_special      = 2
  override_special = "!#$%&*+-_="
}

resource "scaleway_rdb_user" "dlva_app" {
  instance_id = scaleway_rdb_instance.dlva.id
  name        = "crm_dlva_app"
  password    = random_password.dlva_db_app.result
  is_admin    = false
}

resource "scaleway_rdb_database" "dlva_app" {
  instance_id = scaleway_rdb_instance.dlva.id
  name        = "app_crm_dlva"
}

resource "scaleway_rdb_privilege" "dlva_app" {
  instance_id   = scaleway_rdb_instance.dlva.id
  database_name = scaleway_rdb_database.dlva_app.name
  user_name     = scaleway_rdb_user.dlva_app.name
  permission    = "all"

  depends_on = [scaleway_rdb_database.dlva_app, scaleway_rdb_user.dlva_app]
}

# ── Namespace K8s + secret DB (mêmes conventions que les 6 apps) ─────────────

resource "kubernetes_namespace" "crm_dlva" {
  metadata {
    name = "crm-dlva"
    labels = {
      app         = "crm-dlva"
      environment = local.env
    }
  }

  depends_on = [scaleway_k8s_pool.default]
}

resource "kubernetes_secret" "crm_dlva_db" {
  metadata {
    name      = "db-credentials"
    namespace = kubernetes_namespace.crm_dlva.metadata[0].name
  }

  data = {
    DATABASE_URL = format(
      "postgres://%s:%s@%s:%d/%s?sslmode=require",
      scaleway_rdb_user.dlva_app.name,
      urlencode(random_password.dlva_db_app.result),
      scaleway_rdb_instance.dlva.private_network[0].ip,
      scaleway_rdb_instance.dlva.private_network[0].port,
      scaleway_rdb_database.dlva_app.name,
    )
  }

  type = "Opaque"
}

# ── Object Storage media DLVA (même pattern que crm-media.tf) ────────────────

resource "scaleway_object_bucket" "crm_dlva_media" {
  name       = "dlva-crm-prod"
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

resource "scaleway_iam_application" "crm_dlva_media" {
  name        = "crm-dlva-media-prod"
  description = "Accès S3 au bucket dlva-crm-prod pour le pod CRM DLVA"
}

resource "scaleway_iam_policy" "crm_dlva_media" {
  application_id = scaleway_iam_application.crm_dlva_media.id
  name           = "crm-dlva-media-prod"
  description    = "Accès Object Storage pour le pod CRM DLVA (bucket cible : dlva-crm-prod)"

  rule {
    project_ids          = [var.project_id]
    permission_set_names = ["ObjectStorageFullAccess"]
  }
}

resource "scaleway_iam_api_key" "crm_dlva_media" {
  application_id     = scaleway_iam_application.crm_dlva_media.id
  description        = "Clé API pour pod CRM DLVA → dlva-crm-prod"
  default_project_id = var.project_id
}

resource "kubernetes_secret" "crm_dlva_media_creds" {
  metadata {
    name      = "media-credentials"
    namespace = kubernetes_namespace.crm_dlva.metadata[0].name
  }

  data = {
    SCW_S3_BUCKET     = scaleway_object_bucket.crm_dlva_media.name
    SCW_S3_ENDPOINT   = "https://s3.${var.scaleway_region}.scw.cloud"
    SCW_S3_REGION     = var.scaleway_region
    SCW_S3_ACCESS_KEY = scaleway_iam_api_key.crm_dlva_media.access_key
    SCW_S3_SECRET_KEY = scaleway_iam_api_key.crm_dlva_media.secret_key
  }

  type = "Opaque"
}

# ── DNS crm.dlva.04.satkaar.io → LB Ingress (même IP que les autres apps) ────

resource "ovh_domain_zone_record" "crm_dlva_04" {
  count = var.enable_dns_records ? 1 : 0

  zone      = var.ovh_zone
  subdomain = "crm.dlva.04"
  fieldtype = "A"
  ttl       = 300
  target    = local.ingress_lb_ip
}

# ── Outputs ──────────────────────────────────────────────────────────────────

output "dlva_postgres_endpoint_ip" {
  description = "IP privée (VPC) de l'instance Postgres DLVA."
  value       = scaleway_rdb_instance.dlva.private_network[0].ip
}

output "dlva_database_url" {
  description = "DSN complète de la base DLVA (sensible)."
  value       = kubernetes_secret.crm_dlva_db.data.DATABASE_URL
  sensitive   = true
}
