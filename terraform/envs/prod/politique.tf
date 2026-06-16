# ──────────────────────────────────────────────────────────────────────────────
# politique — « Magalie et Marie by satkaar » (Django 6, repo satkaar/politique).
# Outil de communication politique / réseaux sociaux. Servi sur
# magalie-et-marie.satkaar.io (preprod : preprod.magalie-et-marie.satkaar.io).
#
# SANS Postgres (choix assumé) : base SQLite PERSISTANTE sur un PVC déclaré dans
# la chart Helm (values politique : persistence.enabled=true). Conséquences :
#   - pas de db/user sur l'instance RDB mutualisée, pas de secret db-credentials
#     (le caller passe require-db=false au reusable-deploy)
#   - values Helm : envFromSecrets=null + DATABASE_URL=sqlite:////data/db.sqlite3
#
# Déclaré hors de local.apps (comme satkaar-site) car ces apps n'ont ni db ni
# le mapping subdomain → record DNS de local.apps.
#
# Secret applicatif (DJANGO_SECRET_KEY) — créé manuellement par environnement :
#   kubectl -n politique create secret generic politique-secrets \
#     --from-literal=DJANGO_SECRET_KEY=$(openssl rand -hex 32)
#   kubectl -n politique-preprod create secret generic politique-secrets \
#     --from-literal=DJANGO_SECRET_KEY=$(openssl rand -hex 32)
# ──────────────────────────────────────────────────────────────────────────────

locals {
  politique_envs = {
    "prod"    = { namespace = "politique", subdomain = "magalie-et-marie" }
    "preprod" = { namespace = "politique-preprod", subdomain = "preprod.magalie-et-marie" }
  }
}

# ── Namespaces K8s ───────────────────────────────────────────────────────────

resource "kubernetes_namespace" "politique" {
  for_each = local.politique_envs

  metadata {
    name = each.value.namespace
    labels = {
      app         = "politique"
      environment = each.key
    }
  }

  depends_on = [scaleway_k8s_pool.default]
}

# ── DNS : magalie-et-marie.satkaar.io + preprod.* → LB Ingress ───────────────

resource "ovh_domain_zone_record" "politique" {
  for_each = var.enable_dns_records ? local.politique_envs : {}

  zone      = var.ovh_zone
  subdomain = each.value.subdomain
  fieldtype = "A"
  ttl       = 300
  target    = local.ingress_lb_ip
}
