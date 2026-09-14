# acme

Let's Encrypt certificates via certbot, over the dns-01 challenge.

**Outcome:** one certificate covering every name in `acme_domains`, under `/etc/letsencrypt/live/<acme_cert_name>/`, renewing itself, with a deploy hook that reloads angie when it does.
**Idempotent:** yes — the names the lineage already covers are compared against `acme_domains`, and certbot runs only when they differ.
**Atomic:** no.
**Rollback:** none built in. Certificates are left in place; the credentials file and deploy hook are backed up on change. To start over, remove `/etc/letsencrypt/live/<acme_cert_name>/` and re-run.

dns-01 rather than http-01: the certificate is issued before the domain takes any traffic, port 80 never has to be opened for a challenge, and a name pointing at several nodes at once — a shared apex — can still be validated on each of them.

## Why not `creates:`

A `creates:` guard matches as soon as *any* certificate exists for the lineage. Adding an alias to `acme_domains` would then silently do nothing, and angie would go on serving a certificate that does not cover the new name — a failure that only shows up in a browser, days later. So the role reads `certbot certificates --cert-name` and compares the SAN list instead.

The lineage is keyed by inventory hostname rather than by the first domain, so renaming a domain updates the existing lineage instead of stranding it and starting a second one.

## Requirements

* A DNS provider credential in the vault. For the default Cloudflare provider that is `vault_cf_api_token`, an API token scoped to `Zone:DNS:Edit` on the relevant zone.
* DNS records must already resolve — run the Terraform in `terraform/` first.
* `acme_email` must be set. It has no default on purpose.

## Variables

Full specification with types and defaults: [`meta/argument_specs.yml`](meta/argument_specs.yml).

| Variable | Default | Purpose |
|---|---|---|
| `acme_email` | *(required)* | Where Let's Encrypt sends expiry notices |
| `acme_domains` | `{{ vpn_domains }}` | Every name the certificate covers |
| `acme_cert_name` | `{{ inventory_hostname }}` | Lineage name, also the directory under `live/` |
| `acme_dns_provider` | `cloudflare` | certbot DNS plugin |
| `acme_config_dir` | `/etc/letsencrypt` | certbot configuration directory |
| `acme_propagation_seconds` | `30` | Wait for the DNS record to propagate |
| `acme_reload_service` | `angie` | Service the renewal hook reloads |
| `acme_required_facts` | `[os_family]` | Facts gathered if the play sets `gather_facts: false` |

## Example

```yaml
- name: Issue TLS certificates
  ansible.builtin.import_role:
    name: acme
  vars:
    acme_email: ops@example.com
    acme_propagation_seconds: 60
```

## Rate limits

Let's Encrypt counts five duplicate certificates per week, where "duplicate" means the same exact set of names. Nodes sharing an apex still get distinct sets — each includes its own per-node name — so the shared apex costs nothing here. Repeatedly re-issuing *one* node's certificate is what runs into it; use `--dry-run` while debugging.

## Adding a DNS provider

`acme_dns_provider` selects both the `python3-certbot-dns-<provider>` package and the `templates/<provider>.ini.j2` credentials template. Supporting another provider means adding that template and the vault variable it reads.
