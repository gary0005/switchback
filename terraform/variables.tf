variable "cf_api_token" {
  type      = string
  sensitive = true
}

variable "cf_zone_id" {
  type = string
}

# Keep in sync with inventory/host_vars/<host>/main.yml: every name in a
# node's vpn_domains needs a record here, and the certificate will not issue
# until it resolves.
#
# A name may appear more than once. Repeating the apex across nodes is a
# deliberate round robin for the site; per-node names must stay unique.
variable "records" {
  type = list(object({
    name    = string
    content = string
  }))
  description = "A records as FQDN and address pairs."
}
