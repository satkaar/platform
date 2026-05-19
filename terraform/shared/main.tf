provider "scaleway" {
  organization_id = var.scaleway_organization_id
  region          = var.scaleway_region
  zone            = var.scaleway_zone
}

resource "scaleway_account_project" "platform" {
  name        = var.project_name
  description = "Plateforme mutualisée Kapsule pour les 6 applis mairie-agglo (Django)"
}

# Bucket pour le state distant. Volontairement dans le projet par défaut de
# l'orga : la clé IAM utilisée localement est scopée au projet par défaut.
resource "scaleway_object_bucket" "tfstate" {
  name   = var.tfstate_bucket_name
  region = var.scaleway_region

  versioning {
    enabled = true
  }
}

resource "scaleway_registry_namespace" "platform" {
  name        = var.registry_namespace
  description = "Images Docker des 6 apps Django déployées sur Kapsule"
  region      = var.scaleway_region
  project_id  = scaleway_account_project.platform.id
  is_public   = false
}
