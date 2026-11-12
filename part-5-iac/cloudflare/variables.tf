# No defaults for account-specific values: supply them via terraform.tfvars
# (see terraform.tfvars.example) or TF_VAR_* environment variables.

variable "cloudflare_api_token" {
  description = "Cloudflare API token with Zone.DNS and Zone.Cache Rules permissions"
  type        = string
  sensitive   = true
}

variable "zone_id" {
  description = "Cloudflare Zone ID of var.zone_name"
  type        = string
}

variable "zone_name" {
  description = "DNS zone the records live in"
  type        = string
  default     = "example.com"
}

variable "record_name" {
  description = "Subdomain of the quote-api service"
  type        = string
  default     = "quote-api"
}

variable "origin_alb_dns" {
  description = "Origin AWS ALB hostname backing the quote-api record"
  type        = string
}

variable "legacy_status_record_id" {
  description = "Record ID of the manually created status CNAME that the import block adopts"
  type        = string
}
