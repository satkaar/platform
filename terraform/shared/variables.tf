variable "scaleway_organization_id" {
  description = "Scaleway organization ID (Console → Settings → Organization ID)."
  type        = string
}

variable "scaleway_region" {
  description = "Scaleway region for all resources."
  type        = string
  default     = "fr-par"
}

variable "scaleway_zone" {
  description = "Default Scaleway zone."
  type        = string
  default     = "fr-par-1"
}

variable "project_name" {
  description = "Name of the dedicated Scaleway project for the mutualised platform."
  type        = string
  default     = "mairie-agglo-platform"
}

variable "tfstate_bucket_name" {
  description = "Object Storage bucket holding remote Terraform state. Must be globally unique."
  type        = string
  default     = "mairie-agglo-platform-tfstate"
}

variable "registry_namespace" {
  description = "Container Registry namespace for the platform (shared between envs)."
  type        = string
  default     = "mairie-agglo-platform"
}
