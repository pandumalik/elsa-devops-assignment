locals {
  fqdn        = "${var.record_name}.${var.zone_name}"
  status_fqdn = "status-${var.record_name}.${var.zone_name}"
  host_match  = "http.host eq \"${local.fqdn}\""
}

# Adopt the manually created status record into Terraform state (no recreate)
import {
  to = cloudflare_dns_record.legacy_status_cname
  id = "${var.zone_id}/${var.legacy_status_record_id}"
}

resource "cloudflare_dns_record" "legacy_status_cname" {
  zone_id = var.zone_id
  name    = local.status_fqdn
  content = var.origin_alb_dns
  type    = "CNAME"
  proxied = true
  ttl     = 1 # Automatic TTL when proxied
  comment = "Adopted from manual Cloudflare dashboard configuration via Terraform import block"
}

resource "cloudflare_dns_record" "quote_api" {
  zone_id = var.zone_id
  name    = local.fqdn
  content = var.origin_alb_dns
  type    = "CNAME"
  proxied = true
  ttl     = 1 # Automatic TTL when proxied
  comment = "Managed by Terraform — production ingress for ${local.fqdn}"
}

resource "cloudflare_ruleset" "quote_api_cache_rules" {
  zone_id     = var.zone_id
  name        = "quote-api-cache-policy"
  description = "Bypass cache on dynamic /api/* endpoints and aggressively cache static assets"
  kind        = "zone"
  phase       = "http_request_cache_settings"

  rules = [
    {
      # Rule 1: never cache dynamic API responses
      action      = "set_cache_settings"
      description = "Bypass Cloudflare cache for dynamic /api/* endpoints on ${local.fqdn}"
      enabled     = true
      expression  = "(${local.host_match} and starts_with(http.request.uri.path, \"/api/\"))"
      action_parameters = {
        cache = false
      }
    },
    {
      # Rule 2: cache static assets at the edge (30 days) and in browsers (7 days)
      action      = "set_cache_settings"
      description = "Aggressively cache static assets for ${local.fqdn}"
      enabled     = true
      expression  = "(${local.host_match} and http.request.uri.path.extension in {\"js\" \"css\" \"png\" \"jpg\" \"jpeg\" \"webp\" \"svg\" \"woff2\" \"ico\"})"
      action_parameters = {
        cache = true
        edge_ttl = {
          mode    = "override_origin"
          default = 2592000 # 30 days
        }
        browser_ttl = {
          mode    = "override_origin"
          default = 604800 # 7 days
        }
      }
    },
  ]
}
