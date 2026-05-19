output "cluster_id" {
  value = scaleway_k8s_cluster.this.id
}

output "cluster_name" {
  value = scaleway_k8s_cluster.this.name
}

output "kubeconfig" {
  description = "Kubeconfig brut pour le cluster Kapsule (sensible)."
  value       = scaleway_k8s_cluster.this.kubeconfig[0].config_file
  sensitive   = true
}

output "postgres_endpoint_ip" {
  value = scaleway_rdb_instance.shared.endpoint_ip
}

output "postgres_endpoint_port" {
  value = scaleway_rdb_instance.shared.endpoint_port
}

output "ingress_lb_ip" {
  description = "IP publique du LoadBalancer Ingress NGINX (visible après le 1er apply, à utiliser pour enable_dns_records=true)."
  value       = local.ingress_lb_ip
}

output "apps" {
  description = "Liste des apps et leurs sous-domaines."
  value = {
    for k, v in local.apps : k => {
      fqdn      = "${v.subdomain}.${var.ovh_zone}"
      db_name   = v.db_name
      db_user   = v.db_user
      namespace = k
    }
  }
}

output "apps_preprod" {
  description = "Liste des apps preprod (mêmes apps que prod, suffixe _preprod sur DB et namespace -preprod)."
  value = {
    for k, v in local.apps_preprod : k => {
      fqdn      = "preprod.${v.subdomain}.${var.ovh_zone}"
      db_name   = v.db_name
      db_user   = v.db_user
      namespace = "${k}-preprod"
    }
  }
}
