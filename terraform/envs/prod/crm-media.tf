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
      bucket    = "ccfml-crm-prod"
      namespace = kubernetes_namespace.app["crm-mairie-agglo"].metadata[0].name
    }
    preprod = {
      bucket    = "ccfml-crm-preprod"
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

# Rule IAM project-wide pour permettre les ops S3. Le permission set
# ObjectStorageFullAccess n'est pas scopable au bucket via IAM, donc
# l'application a techniquement accès à tous les buckets du projet
# `mairie-agglo-platform`.
#
# NOTE: On évite délibérément `scaleway_object_bucket_policy` ici. Une
# bucket policy mal formulée (sans Allow explicite pour le project owner)
# peut verrouiller le bucket de manière irréversible (même TF ne peut plus
# refresh). L'isolation entre prod/preprod est portée par 2 IAM
# applications distinctes ayant chacune leurs propres credentials —
# aucune logique Django ne pousse l'access_key de preprod sur le bucket
# prod ou inversement.
resource "scaleway_iam_policy" "crm_media" {
  for_each = local.crm_media_envs

  application_id = scaleway_iam_application.crm_media[each.key].id
  name           = "crm-mairie-agglo-media-${each.key}"
  description    = "Accès Object Storage pour le pod CRM ${each.key} (bucket cible : ${each.value.bucket})"

  rule {
    project_ids          = [var.project_id]
    permission_set_names = ["ObjectStorageFullAccess"]
  }
}

resource "scaleway_iam_api_key" "crm_media" {
  for_each = local.crm_media_envs

  application_id     = scaleway_iam_application.crm_media[each.key].id
  description        = "Clé API pour pod CRM ${each.key} → ${each.value.bucket}"
  # Important : sans ce champ, Scaleway utilise le default project du provider
  # (souvent satkaar-dev) → les requêtes S3 résolvent les buckets dans le mauvais
  # projet et tombent en AccessDenied même si la rule IAM autorise.
  default_project_id = var.project_id
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
