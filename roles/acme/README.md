# acme

Let's Encrypt certificates over dns-01, issued **on the controller** and shipped to the nodes.

**Outcome:** one certificate per node covering every name in `acme_domains`, and `fullchain.pem` plus `privkey.pem` installed in `acme_node_cert_dir` on that node.
**Idempotent:** yes — certbot runs only when the lineage's names differ from `acme_domains` or something is close enough to expiry; `copy` moves files only when they actually changed.
**Atomic:** no.
**Rollback:** the lineage stays on the controller. To start over, remove `{{ acme_local_dir }}/live/<name>/` and re-run.

## Where things live, and why

| What | Where |
|---|---|
| certbot, the hook, the DNS credential, the lineages | the controller, under `acme_local_dir` |
| `fullchain.pem`, `privkey.pem` | the node, in `acme_node_cert_dir` |

**The node never sees the DNS credential.** That is the whole point of issuing centrally. dns-01 needs a key that can write to the zone, and at this registrar that key is *account-wide* — it cannot be scoped to one domain, one record type, or one address. A node holding it would hand an intruder every domain in the account, not just this deployment's. Keeping it on one machine you control means a compromised node leaks its own certificate and nothing more.

`acme_local_dir` is deliberately outside the repository, so no `git add -A` can sweep a private key or an API key into a commit.

## What it costs: renewal is not unattended

Nothing on a node notices an expiring certificate, and there is no certbot timer anywhere. **Certificates renew only when this playbook runs.**

Two things soften that:

* `acme_renew_days` is 45 rather than certbot's 30, so there is a month and a half of slack rather than one month.
* Let's Encrypt emails `acme_email` when a certificate is close to expiry. That address is the backstop — keep it one you read.

Set yourself a reminder, or a monthly `--tags certs` run, and the margin is never tested:

```bash
uv run ansible-playbook site.yml --tags certs --ask-vault-pass
```

That run is cheap: it asks certbot what is close to expiring, does nothing if the answer is nothing, and ships new files only if any were produced.

## The hook

`{{ acme_local_dir }}/dns-hook.sh` is called by certbot twice per name, on the controller:

```
dns-hook.sh add       # publish the challenge, wait until it is visible
dns-hook.sh remove    # take it down again
```

It is a script in this repository rather than a third-party certbot plugin. The available one is a single maintainer's package, installable only through pip, and it handles a credential that can rewrite the zone — worth reading in full instead. The API is two calls:

| Action | Request |
|---|---|
| publish | `PUT /v1/dns/records/{zone}` with `{"force": false, "items": [...]}` |
| remove | `DELETE /v1/dns/records/{zone}` with the record as a bare array |

`PUT` is additive on this API — it merges what is in `items` rather than replacing the zone. Records are addressed relative to the zone, so the apex becomes `_acme-challenge` and `v3.example.com` becomes `_acme-challenge.v3`; that is why `acme_dns_zone` must be the registered domain and not a subdomain.

**The hook waits for its own record** by polling a public resolver rather than sleeping a fixed guess. Publishing is not the same as being visible, and a challenge Let's Encrypt is asked to check too early is a failed issue and a spent rate-limit slot. If the record never appears the hook exits non-zero, so certbot fails rather than asking and being told no.

Cleanup is best effort by design: a challenge record that outlives the run is litter, and failing there would turn a successful issue into an error.

## Requirements

* **certbot on the controller.** `brew install certbot` on macOS, `apt install certbot` on Debian or Ubuntu. The role checks and fails with that message if it is missing.
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
| `acme_local_dir` | `~/.local/share/switchback/acme` | Everything certbot owns, on the controller |
| `acme_node_cert_dir` | `/etc/ssl/switchback/<name>` | Where the files land on the node; must match `angie_cert_dir` |
| `acme_renew_days` | `45` | Renew anything expiring within this many days |
| `acme_dns_api_base` | `https://spaceship.dev/api/v1` | Provider API root |
| `acme_dns_ttl` | `60` | TTL of the challenge record |
| `acme_dns_check_resolver` | `1.1.1.1` | Resolver polled to confirm visibility |
| `acme_dns_check_tries` / `acme_dns_check_interval` | `30` / `5` | How long the hook waits, in tries × seconds |
| `acme_reload_service` | `angie` | Reloaded on the node when a new certificate lands |

## Example

```yaml
- name: Issue TLS certificates
  ansible.builtin.import_role:
    name: acme
  vars:
    acme_email: ops@example.com
    acme_dns_check_tries: 60      # a slow zone
```

## Back up the controller's directory

`acme_local_dir` holds every lineage and every private key. Losing it is not fatal — certificates can be reissued — but reissuing five nodes at once runs into Let's Encrypt's limit of five duplicate certificates per week, per exact set of names. Back it up with the vault password, or be prepared to wait.

## Rate limits and debugging

Five duplicate certificates per week, fifty per registered domain. Use `--dry-run` while debugging, so a failed experiment costs nothing:

```bash
CERT_DIR=~/.local/share/switchback/acme
certbot --config-dir "$CERT_DIR" --work-dir "$CERT_DIR/work" --logs-dir "$CERT_DIR/logs" \
  certonly --dry-run --manual --preferred-challenges dns \
  --manual-auth-hook "$CERT_DIR/dns-hook.sh add" \
  --manual-cleanup-hook "$CERT_DIR/dns-hook.sh remove" \
  --cert-name v3 -d v3.example.com -d example.com
```

## Known gap

Nothing watches expiry except Let's Encrypt's own email. A monitoring check on the certificate served by each node would close that; see the repository's "Known gaps".
