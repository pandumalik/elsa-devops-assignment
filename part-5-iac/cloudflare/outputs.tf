output "quote_api_fqdn" {
  description = "Fully qualified domain name of the proxied quote-api DNS record"
  value       = cloudflare_dns_record.quote_api.name
}

output "cache_ruleset_id" {
  description = "ID of the Cloudflare http_request_cache_settings ruleset"
  value       = cloudflare_ruleset.quote_api_cache_rules.id
}
