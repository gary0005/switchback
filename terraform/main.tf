terraform {
  required_providers {
    cloudflare = {
      source = "cloudflare/cloudflare"
      # v5 renamed cloudflare_record to cloudflare_dns_record, made `name` a
      # full FQDN and dropped allow_overwrite. Pinned to the major so a
      # provider upgrade is a deliberate edit rather than a surprise on the
      # next init.
      version = "~> 5.0"
    }
  }
}

provider "cloudflare" {
  api_token = var.cf_api_token
}

# DNS-only (grey cloud): Cloudflare proxying terminates TLS itself, which
# replaces angie's fingerprint with Cloudflare's and drops direct h3 —
# the two things the nodes are configured for.
#
# Keyed by name *and* address, so one name may carry several records. That is
# what puts the shared apex on more than one node: clients land on whichever
# address they are handed, which is fine for a site and useless for a chain —
# a chain has to reach the node it names, so it uses the per-node name.
resource "cloudflare_dns_record" "node" {
  for_each = { for r in var.records : "${r.name}|${r.content}" => r }

  zone_id = var.cf_zone_id
  name    = each.value.name
  content = each.value.content
  type    = "A"
  proxied = false
  ttl     = 300
}
