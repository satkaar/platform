# ──────────────────────────────────────────────────────────────────────────────
# satkaar-site — vitrine corporate Satkaar SAS (Django 6, repo
# satkaar/satkaar-site). Servie sur l'APEX satkaar.io (pas un sous-domaine
# comme les 6 apps métier), avec une preprod sur preprod.satkaar.io.
#
# SANS Postgres (choix assumé) : simple vitrine, SQLite éphémère dans le
# conteneur suffit. Les messages du formulaire de contact ne survivent pas à
# un redéploiement — la notification email (CONTACT_NOTIFICATION_EMAIL) est
# le canal de référence. Conséquences :
#   - pas de db/user sur l'instance RDB mutualisée, pas de secret
#     db-credentials (le caller passe require-db=false au reusable-deploy)
#   - values Helm : envFromSecrets: null (pas d'env DATABASE_URL)
#
# Déclaré hors de local.apps car les records DNS des apps sont dérivés de
# `subdomain` (apex = subdomain vide, et le record preprod généré serait
# "preprod." invalide).
#
# Secrets applicatifs (DJANGO_SECRET_KEY, SMTP plus tard) — pattern
# satkaar-site-secrets, créés manuellement :
#   kubectl -n satkaar-site create secret generic satkaar-site-secrets \
#     --from-literal=DJANGO_SECRET_KEY=$(openssl rand -hex 32)
# ──────────────────────────────────────────────────────────────────────────────

locals {
  satkaar_site_envs = {
    "prod"    = { namespace = "satkaar-site" }
    "preprod" = { namespace = "satkaar-site-preprod" }
  }
}

# ── Namespaces K8s ───────────────────────────────────────────────────────────

resource "kubernetes_namespace" "satkaar_site" {
  for_each = local.satkaar_site_envs

  metadata {
    name = each.value.namespace
    labels = {
      app         = "satkaar-site"
      environment = each.key
    }
  }

  depends_on = [scaleway_k8s_pool.default]
}

# ── DNS : apex satkaar.io + preprod.satkaar.io → LB Ingress ──────────────────

resource "ovh_domain_zone_record" "satkaar_site_apex" {
  count = var.enable_dns_records ? 1 : 0

  zone      = var.ovh_zone
  subdomain = ""
  fieldtype = "A"
  ttl       = 300
  target    = local.ingress_lb_ip
}

resource "ovh_domain_zone_record" "satkaar_site_preprod" {
  count = var.enable_dns_records ? 1 : 0

  zone      = var.ovh_zone
  subdomain = "preprod"
  fieldtype = "A"
  ttl       = 300
  target    = local.ingress_lb_ip
}
