# acme

Let's Encrypt certificates via certbot, over the dns-01 challenge, answered through the registrar's API by a hook installed here.

**Outcome:** one certificate covering every name in `acme_domains`, under `/etc/letsencrypt/live/<acme_cert_name>/`, renewing itself unattended.
**Idempotent:** yes — the names the lineage already covers are compared against `acme_domains`, and certbot runs only when they differ.
**Atomic:** no.
**Rollback:** none built in. Certificates are left in place; the hook and credentials file are backed up on change. To start over, remove `/etc/letsencrypt/live/<acme_cert_name>/` and re-run.

## Why dns-01, and what it costs

http-01 is answered by whichever node the name resolves to. That rules out a name pointing at more than one node — the shared apex does exactly that — because only one node would hold the challenge file and renewal would then succeed or fail by luck. It also needs port 80 reachable forever, and ties issuing to angie already being up.

dns-01 has none of those constraints: ownership is proven by writing a TXT record, so any node can prove any name in the zone, the certificate is issued before the domain takes traffic, and port 80 is needed only for the redirect.

**The cost is the credential.** Every node holds an API key that can write to the whole zone. A node that is broken into can therefore issue a certificate for any name in the domain, or repoint it. This is the largest single risk in the deployment, and it is deliberate — accepted in exchange for the shared apex. Scope the key to DNS writes and nothing else, and rotate it if a node is ever lost.

## The hook

`{{ acme_hook_dir }}/dns-hook.sh` is called by certbot twice per name:

```
dns-hook.sh add       # publish the challenge, wait until it is visible
dns-hook.sh remove    # take it down again
```

It is a script in this repository rather than a third-party certbot plugin. The available one is a single maintainer's package, installable only through pip, and it would run as root holding a credential that can rewrite the zone — worth reading in full instead. The API is two calls:

| Action | Request |
|---|---|
| publish | `PUT /v1/dns/records/{zone}` with `{"force": false, "items": [...]}` |
| remove | `DELETE /v1/dns/records/{zone}` with the record as a bare array |

`PUT` is additive on this API — it merges what is in `items` rather than replacing the zone. Records are addressed relative to the zone, so the apex becomes `_acme-challenge` and `v3.example.com` becomes `_acme-challenge.v3`; that is why `acme_dns_zone` must be the registered domain and not a subdomain.

**The hook waits for its own record** by polling a public resolver, rather than sleeping a fixed guess. Publishing is not the same as being visible, and a challenge Let's Encrypt is asked to check too early is a failed issue and a spent rate-limit slot. If the record never appears the hook exits non-zero, so certbot fails rather than asking and being told no.

Cleanup is best effort by design: a challenge record that outlives the run is litter, and failing there would turn a successful issue into an error.

## Renewal

The hooks are written into the lineage's renewal configuration, which is what makes the manual plugin renew unattended — certbot's own timer replays them. Nothing else is scheduled by this role.

The hook reads `CERTBOT_IDENTIFIER`, falling back to `CERTBOT_DOMAIN`: recent certbot renamed the variable, and accepting both means a version bump cannot silently break renewal sixty days from now.

## Requirements

* `acme_dns_zone`, `acme_dns_api_key` and `acme_dns_api_secret`, bridged from the vault in `group_vars/all/main.yml`.
* Every name in `acme_domains` must exist in that zone. The records themselves are maintained by hand; `--tags verify` checks they still match the inventory.
* `acme_email` must be set. It has no default on purpose.

## Variables

Full specification with types and defaults: [`meta/argument_specs.yml`](meta/argument_specs.yml).

| Variable | Default | Purpose |
|---|---|---|
| `acme_email` | *(required)* | Where Let's Encrypt sends expiry notices |
| `acme_domains` | `{{ vpn_domains }}` | Every name the certificate covers |
| `acme_cert_name` | `{{ inventory_hostname }}` | Lineage name, also the directory under `live/` |
| `acme_dns_zone` | *(required)* | Zone challenge records are written into |
| `acme_dns_api_key` / `acme_dns_api_secret` | *(required)* | Credentials for that zone's API |
| `acme_dns_api_base` | `https://spaceship.dev/api/v1` | Provider API root |
| `acme_dns_credentials` | `/etc/letsencrypt/dns-api.env` | Env file the hook sources, mode 0600 |
| `acme_hook_dir` | `/etc/letsencrypt/hooks` | Where the hook is installed |
| `acme_dns_ttl` | `60` | TTL of the challenge record |
| `acme_dns_check_resolver` | `1.1.1.1` | Resolver polled to confirm visibility |
| `acme_dns_check_tries` / `acme_dns_check_interval` | `30` / `5` | How long the hook waits, in tries × seconds |
| `acme_packages` | `[certbot, bind9-dnsutils]` | dig is not optional; the hook polls with it |
| `acme_reload_service` | `angie` | Reloaded on issue and on renewal |

## Example

```yaml
- name: Issue TLS certificates
  ansible.builtin.import_role:
    name: acme
  vars:
    acme_email: ops@example.com
    acme_dns_check_tries: 60      # a slow zone
```

## Rate limits and debugging

Let's Encrypt counts five duplicate certificates per week — same exact set of names — and fifty per registered domain. The provider's API allows 300 writes per domain per 300 seconds, which matters only when several nodes issue at once.

Use `--dry-run` while debugging, so a failed experiment costs nothing:

```bash
certbot certonly --dry-run --manual --preferred-challenges dns \
  --manual-auth-hook "/etc/letsencrypt/hooks/dns-hook.sh add" \
  --manual-cleanup-hook "/etc/letsencrypt/hooks/dns-hook.sh remove" \
  --cert-name v3 -d v3.example.com -d example.com
```

## Known gap

Nodes sharing the apex issue their challenges concurrently when the playbook runs against all of them at once. Several TXT records under `_acme-challenge` coexist and Let's Encrypt accepts any matching one, so this is expected to work — but it has not been exercised under a slow zone. If issuing turns flaky on a full run, take the nodes one at a time with `--limit`.
