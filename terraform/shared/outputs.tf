output "project_id" {
  description = "À passer en var.project_id pour les stacks envs/."
  value       = scaleway_account_project.platform.id
}

output "registry_endpoint" {
  description = "Endpoint Container Registry (préfixe pour les tags d'image)."
  value       = scaleway_registry_namespace.platform.endpoint
}

output "tfstate_bucket" {
  value = scaleway_object_bucket.tfstate.name
}
