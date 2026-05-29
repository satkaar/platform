# ──────────────────────────────────────────────────────────────────────────────
# Object Storage pour les media du CRM Mairie Agglo (uploads users : photos
# de profil, pièces jointes, etc.). Le filesystem des pods Kapsule est
# éphémère et non partagé entre répliques → S3 obligatoire en prod.
#
# Pattern : 1 bucket par env (crm-ccfml-prod, crm-ccfml-preprod) + 1 IAM
# application dédiée par env, scoping serré via bucket policy (l'app n'a
# accès qu'à son propre bucket, pas aux tfstate / autres buckets du projet).
# Les credentials sont injectés dans un Secret K8s `media-credentials`
# consommé par le chart django-app via envFromSecretRefs.
# ──────────────────────────────────────────────────────────────────────────────

locals {
  crm_media_envs = {
    prod = {
      bucket    = "crm-ccfml-prod"
      namespace = kubernetes_namespace.app["crm-mairie-agglo"].metadata[0].name
    }
    preprod = {
      bucket    = "crm-ccfml-preprod"
      namespace = kubernetes_namespace.app_preprod["crm-mairie-agglo"].metadata[0].name
    }
  }
}

resource "scaleway_object_bucket" "crm_media" {
  for_each = local.crm_media_envs

  name       = each.value.bucket
  project_id = var.project_id
  region     = var.scaleway_region

  versioning {
    enabled = false
  }

  # Photos servies en <img src> direct depuis le bucket ; le navigateur ne fait
  # pas de CORS sur les images, mais on autorise GET pour rester ouvert aux
  # consommations XHR / fetch éventuelles (vignettes générées côté front).
  cors_rule {
    allowed_methods = ["GET", "HEAD"]
    allowed_origins = ["*"]
    allowed_headers = ["*"]
    max_age_seconds = 3600
  }
}

resource "scaleway_iam_application" "crm_media" {
  for_each = local.crm_media_envs

  name        = "crm-mairie-agglo-media-${each.key}"
  description = "Accès S3 au bucket ${each.value.bucket} pour le pod CRM ${each.key}"
}

# Bucket policy : restreint l'accès au bucket à l'application IAM
# correspondante uniquement (l'application n'a aucune permission IAM
# project-wide ; tout passe par cette policy bucket-scopée).
resource "scaleway_object_bucket_policy" "crm_media" {
  for_each = local.crm_media_envs

  bucket = scaleway_object_bucket.crm_media[each.key].name
  policy = jsonencode({
    Version = "2023-04-17"
    Statement = [
      {
        Sid    = "AllowCrmAppFullAccess"
        Effect = "Allow"
        Principal = {
          SCW = "application_id:${scaleway_iam_application.crm_media[each.key].id}"
        }
        Action = ["s3:*"]
        Resource = [
          scaleway_object_bucket.crm_media[each.key].name,
          "${scaleway_object_bucket.crm_media[each.key].name}/*",
        ]
      },
    ]
  })
}

resource "scaleway_iam_api_key" "crm_media" {
  for_each = local.crm_media_envs

  application_id = scaleway_iam_application.crm_media[each.key].id
  description    = "Clé API pour pod CRM ${each.key} → ${each.value.bucket}"
}

# Secret K8s injecté dans le namespace de l'app (un par env). Référencé
# depuis les values Helm via `envFromSecretRefs: [- name: media-credentials]`.
resource "kubernetes_secret" "crm_media_creds" {
  for_each = local.crm_media_envs

  metadata {
    name      = "media-credentials"
    namespace = each.value.namespace
  }

  data = {
    SCW_S3_BUCKET     = scaleway_object_bucket.crm_media[each.key].name
    SCW_S3_ENDPOINT   = "https://s3.${var.scaleway_region}.scw.cloud"
    SCW_S3_REGION     = var.scaleway_region
    SCW_S3_ACCESS_KEY = scaleway_iam_api_key.crm_media[each.key].access_key
    SCW_S3_SECRET_KEY = scaleway_iam_api_key.crm_media[each.key].secret_key
  }

  type = "Opaque"
}
