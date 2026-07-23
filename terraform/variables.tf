variable "cf_api_token" {
  type      = string
  sensitive = true
}

variable "cf_zone_id" {
  type = string
}

# Keep in sync with inventory/hosts.yml.
# Rotating a domain = an edit here and there, one commit.
variable "nodes" {
  type        = map(string)
  description = "subdomain => IP"
}
