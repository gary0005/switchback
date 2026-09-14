# acme

Let's Encrypt certificates via certbot, over the http-01 challenge.

**Outcome:** one certificate covering every name in `acme_domains`, under `/etc/letsencrypt/live/<acme_cert_name>/`, renewing itself, with `/etc/ssl/switchback/current` pointing at it and a deploy hook that reloads angie on renewal.
**Idempotent:** yes — the names the lineage already covers are compared against `acme_domains`, and certbot runs only when they differ.
**Atomic:** no.
**Rollback:** none built in. Certificates are left in place; the deploy hook is backed up on change. To start over, remove `/etc/letsencrypt/live/<acme_cert_name>/`, re-run, and the placeholder carries angie until the new one arrives.

## Why http-01 and what it costs

dns-01 would need an API credential for the zone **on every node**. A node that is broken into could then be used to issue a certificate for any name in the zone, or to repoint the domain — the blast radius of one compromised server becomes the whole domain. http-01 needs no such credential: the node proves it controls the name by answering on its own port 80.

The cost is that **every name must resolve to exactly one node.** Let's Encrypt asks whichever address the name points at, and only one node holds the challenge file. A name on three addresses validates on one of them at random, which means renewal fails about two times in three — sixty days after you stopped watching.

That is why the apex lives on a single node here, and why the `verify` role asserts that each of a node's names resolves to that node and nowhere else.

## The startup deadlock, and the symlink

angie will not start without a certificate file: `ssl_certificate` points at a path, `angie -t` fails if it is missing. certbot cannot produce that file until angie is answering on port 80. Neither can go first.

So angie is never pointed at a lineage. It is pointed at `{{ acme_link_dir }}/current`, and this role runs in two parts:

| Part | When | What it does |
|---|---|---|
| `main.yml` | before angie | installs certbot, creates the webroot, writes a self-signed placeholder, points `current` at it |
| `issue.yml` | after angie is up | obtains or extends the real certificate, moves `current` onto the lineage, reloads angie |

Both call `link.yml`, so the decision about where `current` points is made in one place. The placeholder is served only in the seconds between angie starting and the challenge succeeding, on the very first run.

`site.yml` puts a `meta: flush_handlers` between the two, because angie's config only reaches the running process when its handlers fire.

## Why not `creates:`

A `creates:` guard matches as soon as *any* certificate exists for the lineage. Adding an alias to `acme_domains` would then silently do nothing, and angie would go on serving a certificate that does not cover the new name — a failure that only shows up in a browser, days later. So the role reads `certbot certificates --cert-name` and compares the SAN list instead.

The lineage is keyed by inventory hostname rather than by the first domain, so renaming a domain updates the existing lineage instead of stranding it and starting a second one.

## Requirements

* Every name in `acme_domains` must already resolve to this node. DNS is maintained by hand at the registrar; `--tags verify` is what tells you it still matches.
* Port 80 reachable from the internet, and it has to stay that way — renewal needs it every sixty days.
* angie must serve `/.well-known/acme-challenge/` from `acme_webroot` on port 80, ahead of the redirect to HTTPS. The angie role does this; `angie_acme_webroot` must match `acme_webroot`.
* `acme_email` must be set. It has no default on purpose.

## Variables

Full specification with types and defaults: [`meta/argument_specs.yml`](meta/argument_specs.yml).

| Variable | Default | Purpose |
|---|---|---|
| `acme_email` | *(required)* | Where Let's Encrypt sends expiry notices |
| `acme_domains` | `{{ vpn_domains }}` | Every name the certificate covers |
| `acme_cert_name` | `{{ inventory_hostname }}` | Lineage name, also the directory under `live/` |
| `acme_webroot` | `/var/www/acme` | Where challenge files are written; must match `angie_acme_webroot` |
| `acme_link_dir` | `/etc/ssl/switchback` | Holds the placeholder and the `current` symlink |
| `acme_bootstrap_days` | `3650` | Validity of the placeholder |
| `acme_config_dir` | `/etc/letsencrypt` | certbot configuration directory |
| `acme_reload_service` | `angie` | Reloaded when the symlink moves and on renewal |
| `acme_required_facts` | `[os_family]` | Facts gathered if the play sets `gather_facts: false` |

## Example

```yaml
- name: Prepare for certificate issue
  ansible.builtin.import_role:
    name: acme
  vars:
    acme_email: ops@example.com

# ... angie comes up here ...

- name: Issue TLS certificates
  ansible.builtin.import_role:
    name: acme
    tasks_from: issue
```

## Rate limits

Let's Encrypt counts five duplicate certificates per week, where "duplicate" means the same exact set of names, and fifty per registered domain per week. Use `--dry-run` while debugging rather than burning real attempts:

```bash
certbot certonly --dry-run --webroot -w /var/www/acme --cert-name v3 -d v3.example.com -d example.com
```

## Known gap

Renewal depends on port 80 staying open. Closing it would break renewal silently — certbot's timer keeps running and keeps failing, and the only signal is the expiry notice to `acme_email`. If the firewall role ever stops opening 80, this role stops working sixty days later.
