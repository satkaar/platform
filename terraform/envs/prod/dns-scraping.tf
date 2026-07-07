# Record DNS pour l'app "scraping" (outil de veille réseaux sociaux).
#
# Cette app est déployée HORS de ce terraform (repo satkaar/scraping, namespace
# créé manuellement, base SQLite — pas de Postgres). On ne gère donc ici QUE
# l'entrée DNS A vers l'IP du LoadBalancer Ingress, sans l'ajouter à local.apps
# (qui provisionnerait namespace + base Postgres inutiles).

resource "ovh_domain_zone_record" "scraping" {
  count = var.enable_dns_records ? 1 : 0

  zone      = var.ovh_zone
  subdomain = "scraping"
  fieldtype = "A"
  ttl       = 300
  target    = local.ingress_lb_ip
}
