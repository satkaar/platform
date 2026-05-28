resource "ovh_domain_zone_record" "crm_ccfml_04" {
  count = var.enable_dns_records ? 1 : 0

  zone      = var.ovh_zone
  subdomain = "crm.ccfml.04"
  fieldtype = "A"
  ttl       = 300
  target    = local.ingress_lb_ip
}

resource "ovh_domain_zone_record" "crm_ccfml_04_preprod" {
  count = var.enable_dns_records ? 1 : 0

  zone      = var.ovh_zone
  subdomain = "preprod.crm.ccfml.04"
  fieldtype = "A"
  ttl       = 300
  target    = local.ingress_lb_ip
}
