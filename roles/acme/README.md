# acme

Let's Encrypt certificates over http-01, issued **on the controller**, with the challenge distributed to every node that answers for the name.

**Outcome:** one certificate per node covering every name in `acme_domains`, and `fullchain.pem` plus `privkey.pem` installed in `acme_node_cert_dir` on that node.
**Idempotent:** yes — certbot runs only when the lineage's names differ from `acme_domains` or something is close enough to expiry; `copy` moves files only when they actually changed.
**Atomic:** no.
**Rollback:** the lineage stays on the controller. To start over, remove `{{ acme_local_dir }}/live/<name>/` and re-run; the placeholder carries angie until the new one arrives.

## No credential, anywhere

There is no DNS API key in this deployment — not on a node, not on the controller. That is the point of distributing the challenge rather than answering it in DNS.

dns-01 would need a key that can write to the zone, and at this registrar that key cannot be narrowed: the `dnsrecords:write` scope covers every domain in the account, with no per-domain, per-record-type or per-address restriction. Not having one at all beats guarding one.

## Why the challenge has to go to every node

Let's Encrypt connects to **one** of the addresses a name resolves to. It moves on to another only when the connection itself fails — in [`va/http.go`](https://github.com/letsencrypt/boulder/blob/main/va/http.go) that is limited explicitly: *"By policy, only dial errors (not read or write errors) are eligible for fallback"*. A node that answers on port 80 without the challenge file returns 404, which is not a dial error, so the validation ends there.

The apex resolves to three nodes. Putting the file on one of them is a coin toss, and the order of addresses in a DNS answer rotates. So the hook puts it on all of them — which is what Let's Encrypt's documentation says to do: *"If you have multiple web servers, you have to make sure the file is available on all of them."*

A useful consequence: a node that is **down** during issuing does not break it. The validator gets a connection error there, and a connection error is exactly the case where it does try the next address.

## The two parts

angie will not start without a certificate, and http-01 is answered by angie. Neither can go first, so the role runs in two passes with `meta: flush_handlers` between them — see [`site.yml`](../../site.yml):

| Part | When | What it does |
|---|---|---|
| `main.yml` | before angie | webroot, self-signed placeholder, hook and target map on the controller |
| `issue.yml` | after angie is up | obtains or renews, installs the result over the placeholder |

The placeholder is served only in the seconds between angie starting and the first issue succeeding, on the very first run.

## The hook

`{{ acme_local_dir }}/http-hook.sh` is called by certbot twice per name, on the controller:

```
http-hook.sh add       # write the challenge file to every node carrying the name
http-hook.sh remove    # delete it again
```

It reads `targets.json`, a map of name → ssh targets rendered from the **inventory** rather than from the play. That matters under `--limit`: the play may be one node, but a name carried by three still has to be answered on all three.

`add` is all-or-nothing — the first ssh failure aborts before certbot tells Let's Encrypt to look, because a partial rollout is worse than not trying. `remove` is best effort: a leftover file is litter, not a reason to fail a good issue.

> The `remove` branch passes `ssh -n`. Without it ssh inherits the loop's stdin and swallows the remaining targets, so only the first node is cleaned up. `add` is safe because its stdin is already taken by the pipe feeding the file's content.

## Renewal is not unattended

Nothing on a node notices an expiring certificate, and there is no certbot timer anywhere. **Certificates renew only when this playbook runs.**

Two things soften that:

* `acme_renew_days` is 45 rather than certbot's 30, so there is a month and a half of slack rather than one month.
* Let's Encrypt emails `acme_email` when a certificate is close to expiry. That address is the backstop — keep it one you read.

A monthly run is what actually keeps it alive:

```bash
uv run ansible-playbook site.yml --tags certs --ask-vault-pass
```

It is cheap: it asks certbot what is close to expiring, does nothing if the answer is nothing, and ships files only if any were produced.

## Requirements

* **certbot on the controller.** `brew install certbot` on macOS, `apt install certbot` on Debian or Ubuntu. The role checks and fails with that message if it is missing.
* **ssh from the controller to every node** carrying a name being issued — the same access Ansible already uses.
* **Port 80 open on every node**, and staying open. It is what issuing and renewal run on.
* angie must serve `/.well-known/acme-challenge/` from `acme_webroot` ahead of its redirect; the angie role does this, and `angie_acme_webroot` must match `acme_webroot`.
* `acme_email` must be set. It has no default on purpose.

## Variables

Full specification with types and defaults: [`meta/argument_specs.yml`](meta/argument_specs.yml).

| Variable | Default | Purpose |
|---|---|---|
| `acme_email` | *(required)* | Where Let's Encrypt sends expiry notices |
| `acme_domains` | `{{ vpn_domains }}` | Every name the certificate covers |
| `acme_cert_name` | `{{ inventory_hostname }}` | Lineage name, also the directory under `live/` |
| `acme_local_dir` | `~/.local/share/switchback/acme` | Everything certbot owns, on the controller |
| `acme_node_cert_dir` | `/etc/ssl/switchback/<name>` | Where the files land; must match `angie_cert_dir` |
| `acme_webroot` | `/var/www/acme` | Challenge root on the nodes; must match `angie_acme_webroot` |
| `acme_target_group` / `acme_target_exclude_group` | `vpn` / `unmanaged` | Which nodes the hook may distribute to |
| `acme_ssh_options` | `-o BatchMode=yes -o ConnectTimeout=10` | Options the hook passes to ssh |
| `acme_bootstrap_days` | `3650` | Validity of the placeholder |
| `acme_renew_days` | `45` | Renew anything expiring within this many days |
| `acme_reload_service` | `angie` | Reloaded on the node when a new certificate lands |

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

## Back up the controller's directory

`acme_local_dir` holds every lineage and every private key. Losing it is not fatal — certificates can be reissued — but reissuing several nodes at once runs into Let's Encrypt's limit of five duplicate certificates per week, per exact set of names. Back it up with the vault password, or be prepared to wait.

## Debugging

Use `--dry-run` so a failed experiment costs nothing:

```bash
CERT_DIR=~/.local/share/switchback/acme
certbot --config-dir "$CERT_DIR" --work-dir "$CERT_DIR/work" --logs-dir "$CERT_DIR/logs" \
  certonly --dry-run --manual --preferred-challenges http \
  --manual-auth-hook "$CERT_DIR/http-hook.sh add" \
  --manual-cleanup-hook "$CERT_DIR/http-hook.sh remove" \
  --cert-name v3 -d v3.example.com -d example.com
```

If a validation fails, check in this order: does port 80 answer on every node carrying the name; did the hook reach all of them (`ssh -o BatchMode=yes root@<node> true`); and is the file actually there — `curl http://<node>/.well-known/acme-challenge/test` should reach angie rather than the redirect.

## Known gaps

* Nothing watches expiry except Let's Encrypt's own email.
* Issuing depends on ssh to every node carrying the name. A node that is unreachable but still answering on 80 — a firewall change, say — fails the issue rather than falling back.
