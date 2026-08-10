# acme

Let's Encrypt certificates via certbot, over the dns-01 challenge.

**Outcome:** a valid certificate for the node's domain under `/etc/letsencrypt/live/<domain>/`, renewing itself, with a deploy hook that reloads angie when it does.
**Idempotent:** yes — `certbot certonly` is guarded by `creates:`, so it runs once and is skipped afterwards.
**Atomic:** no.
**Rollback:** none built in. Certificates are left in place; the credentials file and deploy hook are backed up on change. To start over, remove `/etc/letsencrypt/live/<domain>/` and re-run.

dns-01 rather than http-01: the certificate is issued before the domain takes any traffic, and port 80 never has to be opened for a challenge.

## Requirements

* A DNS provider credential in the vault. For the default Cloudflare provider that is `vault_cf_api_token`, an API token scoped to `Zone:DNS:Edit` on the relevant zone.
* DNS records must already resolve — run the Terraform in `terraform/` first.
* `acme_email` must be set. It has no default on purpose.

## Variables

Full specification with types and defaults: [`meta/argument_specs.yml`](meta/argument_specs.yml).

| Variable | Default | Purpose |
|---|---|---|
| `acme_email` | *(required)* | Where Let's Encrypt sends expiry notices |
| `acme_domain` | `{{ public_domain }}` | Name the certificate is issued for |
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

## Adding a DNS provider

`acme_dns_provider` selects both the `python3-certbot-dns-<provider>` package and the `templates/<provider>.ini.j2` credentials template. Supporting another provider means adding that template and the vault variable it reads.
