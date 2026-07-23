terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }
}

provider "cloudflare" {
  api_token = var.cf_api_token
}

# DNS-only (grey cloud): Cloudflare proxying adds its own TLS fingerprint
# and breaks direct h3 to angie.
resource "cloudflare_record" "node" {
  for_each = var.nodes

  zone_id = var.cf_zone_id
  name    = each.key
  content = each.value
  type    = "A"
  proxied = false
  ttl     = 300
}
