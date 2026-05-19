variable "scaleway_organization_id" {
  description = "Scaleway organization ID."
  type        = string
}

variable "project_id" {
  description = "Scaleway project ID (output de la stack shared/)."
  type        = string
}

variable "scaleway_region" {
  description = "Scaleway region."
  type        = string
  default     = "fr-par"
}

variable "scaleway_zone" {
  description = "Default Scaleway zone."
  type        = string
  default     = "fr-par-1"
}

variable "ovh_zone" {
  description = "Apex domain géré chez OVH (records A pour les sous-domaines des apps)."
  type        = string
  default     = "satkaar.io"
}

variable "cluster_name" {
  description = "Nom du cluster Kapsule."
  type        = string
  default     = "mairie-agglo-prod"
}

variable "kubernetes_version" {
  description = "Version Kubernetes pour Kapsule."
  type        = string
  default     = "1.31.2"
}

variable "node_type" {
  description = "Type d'Instance Scaleway pour les nœuds du pool."
  type        = string
  default     = "PRO2-XXS"
}

variable "pool_size" {
  description = "Taille initiale du pool."
  type        = number
  default     = 3
}

variable "pool_min_size" {
  description = "Taille mini pour l'autoscaler."
  type        = number
  default     = 3
}

variable "pool_max_size" {
  description = "Taille maxi pour l'autoscaler."
  type        = number
  default     = 5
}

variable "postgres_node_type" {
  description = "Type d'instance Managed DB (mutualisée pour les 6 apps)."
  type        = string
  default     = "DB-DEV-S"
}

variable "postgres_volume_size_gb" {
  description = "Volume Postgres en Go."
  type        = number
  default     = 20
}

variable "letsencrypt_email" {
  description = "Email utilisé par cert-manager pour les certificats Let's Encrypt."
  type        = string
}

variable "enable_dns_records" {
  description = "Si true, crée les records A OVH pointant sur l'IP du LoadBalancer Ingress. Faire un premier apply à false (le temps que le LB soit attribué), puis re-apply à true."
  type        = bool
  default     = false
}
