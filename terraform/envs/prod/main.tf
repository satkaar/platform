locals {
  env = "prod"

  apps = {
    "entreprise" = {
      subdomain = "entreprise"
      db_name   = "app_entreprise"
      db_user   = "entreprise_app"
    }
    "ecole" = {
      subdomain = "ecole"
      db_name   = "app_ecole"
      db_user   = "ecole_app"
    }
    "creche" = {
      subdomain = "creche"
      db_name   = "app_creche"
      db_user   = "creche_app"
    }
    "association" = {
      subdomain = "association"
      db_name   = "app_association"
      db_user   = "association_app"
    }
    "document-citoyen" = {
      subdomain = "documents"
      db_name   = "app_document_citoyen"
      db_user   = "document_citoyen_app"
    }
    "crm-mairie-agglo" = {
      subdomain = "crm"
      db_name   = "app_crm"
      db_user   = "crm_app"
    }
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# Providers
# ──────────────────────────────────────────────────────────────────────────────

provider "scaleway" {
  organization_id = var.scaleway_organization_id
  project_id      = var.project_id
  region          = var.scaleway_region
  zone            = var.scaleway_zone
}

provider "ovh" {
  endpoint = "ovh-eu"
}

provider "kubernetes" {
  host  = scaleway_k8s_cluster.this.kubeconfig[0].host
  token = scaleway_k8s_cluster.this.kubeconfig[0].token
  cluster_ca_certificate = base64decode(
    scaleway_k8s_cluster.this.kubeconfig[0].cluster_ca_certificate
  )
}

provider "helm" {
  kubernetes {
    host  = scaleway_k8s_cluster.this.kubeconfig[0].host
    token = scaleway_k8s_cluster.this.kubeconfig[0].token
    cluster_ca_certificate = base64decode(
      scaleway_k8s_cluster.this.kubeconfig[0].cluster_ca_certificate
    )
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# Réseau privé (VPC)
# ──────────────────────────────────────────────────────────────────────────────

resource "scaleway_vpc" "this" {
  name       = "${var.cluster_name}-vpc"
  project_id = var.project_id
  region     = var.scaleway_region
}

resource "scaleway_vpc_private_network" "this" {
  name       = "${var.cluster_name}-pn"
  vpc_id     = scaleway_vpc.this.id
  project_id = var.project_id
  region     = var.scaleway_region
}

# ──────────────────────────────────────────────────────────────────────────────
# Cluster Kapsule (control plane managé gratuit, hors version Dedicated)
# ──────────────────────────────────────────────────────────────────────────────

resource "scaleway_k8s_cluster" "this" {
  name                        = var.cluster_name
  project_id                  = var.project_id
  region                      = var.scaleway_region
  version                     = var.kubernetes_version
  cni                         = "cilium"
  description                 = "Cluster Kapsule mutualisé pour les 6 apps Django"
  delete_additional_resources = true
  private_network_id          = scaleway_vpc_private_network.this.id

  auto_upgrade {
    enable                        = false
    maintenance_window_start_hour = 3
    maintenance_window_day        = "sunday"
  }
}

resource "scaleway_k8s_pool" "default" {
  cluster_id  = scaleway_k8s_cluster.this.id
  name        = "default"
  node_type   = var.node_type
  size        = var.pool_size
  min_size    = var.pool_min_size
  max_size    = var.pool_max_size
  autoscaling = true
  autohealing = true
  zone        = var.scaleway_zone
}

# ──────────────────────────────────────────────────────────────────────────────
# Postgres mutualisé : 1 instance, 6 databases, 6 users isolés
# ──────────────────────────────────────────────────────────────────────────────

resource "random_password" "db_admin" {
  length           = 32
  special          = true
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
  min_special      = 2
  override_special = "!#$%&*+-_="
}

# Endpoint LB public conservé pour la migration data initiale depuis local
# (SQLite → Postgres). À durcir plus tard : passer en private_network seul
# une fois la migration faite, et utiliser un peering avec le VPC Kapsule.
resource "scaleway_rdb_instance" "shared" {
  name                      = "platform-${local.env}"
  project_id                = var.project_id
  region                    = var.scaleway_region
  node_type                 = var.postgres_node_type
  engine                    = "PostgreSQL-16"
  user_name                 = "platform_admin"
  password                  = random_password.db_admin.result
  volume_size_in_gb         = var.postgres_volume_size_gb
  volume_type               = "sbs_5k"
  disable_backup            = false
  backup_schedule_frequency = 24
  backup_schedule_retention = 7
}

resource "random_password" "db_app" {
  for_each = local.apps

  length           = 32
  special          = true
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
  min_special      = 2
  override_special = "!#$%&*+-_="
}

resource "scaleway_rdb_user" "app" {
  for_each = local.apps

  instance_id = scaleway_rdb_instance.shared.id
  name        = each.value.db_user
  password    = random_password.db_app[each.key].result
  is_admin    = false
}

resource "scaleway_rdb_database" "app" {
  for_each = local.apps

  instance_id = scaleway_rdb_instance.shared.id
  name        = each.value.db_name
}

resource "scaleway_rdb_privilege" "app" {
  for_each = local.apps

  instance_id   = scaleway_rdb_instance.shared.id
  database_name = scaleway_rdb_database.app[each.key].name
  user_name     = scaleway_rdb_user.app[each.key].name
  permission    = "all"

  depends_on = [scaleway_rdb_database.app, scaleway_rdb_user.app]
}

# ──────────────────────────────────────────────────────────────────────────────
# Ingress NGINX + cert-manager (Helm releases)
# ──────────────────────────────────────────────────────────────────────────────

resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  namespace        = "ingress-nginx"
  create_namespace = true
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  version          = "4.11.3"

  set {
    name  = "controller.service.type"
    value = "LoadBalancer"
  }

  # WebSocket : timeouts longs nécessaires
  set {
    name  = "controller.config.proxy-read-timeout"
    value = "3600"
  }
  set {
    name  = "controller.config.proxy-send-timeout"
    value = "3600"
  }

  depends_on = [scaleway_k8s_pool.default]
}

resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  namespace        = "cert-manager"
  create_namespace = true
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = "v1.16.1"

  set {
    name  = "installCRDs"
    value = "true"
  }

  depends_on = [scaleway_k8s_pool.default]
}

# NOTE : le ClusterIssuer Let's Encrypt n'est PAS créé en Terraform car
# kubernetes_manifest exige les CRDs cert-manager au plan time, ce qui crée
# un chicken-and-egg au 1er apply. Il est appliqué après le 1er apply via :
#   make apply-issuer LETSENCRYPT_EMAIL=damien.marque.dm@gmail.com
# (voir Makefile et scripts/cert-manager-issuer.yaml)

# ──────────────────────────────────────────────────────────────────────────────
# Récupération de l'IP publique du LoadBalancer Ingress (pour les records DNS)
# ──────────────────────────────────────────────────────────────────────────────

resource "time_sleep" "wait_for_lb" {
  depends_on      = [helm_release.ingress_nginx]
  create_duration = "120s"
}

data "kubernetes_service" "ingress_nginx" {
  count = var.enable_dns_records ? 1 : 0

  metadata {
    name      = "ingress-nginx-controller"
    namespace = "ingress-nginx"
  }

  depends_on = [time_sleep.wait_for_lb]
}

locals {
  ingress_lb_ip = var.enable_dns_records ? data.kubernetes_service.ingress_nginx[0].status[0].load_balancer[0].ingress[0].ip : ""
}

# ──────────────────────────────────────────────────────────────────────────────
# Records DNS OVH (1 record A par app, vers l'IP du LoadBalancer Ingress)
# Premier apply à enable_dns_records=false, second apply à true.
# ──────────────────────────────────────────────────────────────────────────────

resource "ovh_domain_zone_record" "app" {
  for_each = var.enable_dns_records ? local.apps : {}

  zone      = var.ovh_zone
  subdomain = each.value.subdomain
  fieldtype = "A"
  ttl       = 300
  target    = local.ingress_lb_ip
}

# ──────────────────────────────────────────────────────────────────────────────
# Namespaces K8s par app (utilisés par les Helm releases applicatives)
# ──────────────────────────────────────────────────────────────────────────────

resource "kubernetes_namespace" "app" {
  for_each = local.apps

  metadata {
    name = each.key
    labels = {
      app         = each.key
      environment = local.env
    }
  }

  depends_on = [scaleway_k8s_pool.default]
}

# ──────────────────────────────────────────────────────────────────────────────
# Secret K8s par app : credentials Postgres consommés par le chart Helm
# ──────────────────────────────────────────────────────────────────────────────

resource "kubernetes_secret" "db" {
  for_each = local.apps

  metadata {
    name      = "db-credentials"
    namespace = kubernetes_namespace.app[each.key].metadata[0].name
  }

  data = {
    DATABASE_URL = format(
      "postgres://%s:%s@%s:%d/%s?sslmode=require",
      scaleway_rdb_user.app[each.key].name,
      urlencode(random_password.db_app[each.key].result),
      scaleway_rdb_instance.shared.load_balancer[0].ip,
      scaleway_rdb_instance.shared.load_balancer[0].port,
      scaleway_rdb_database.app[each.key].name,
    )
  }

  type = "Opaque"
}
