# subscription

Static per-user subscription payloads and a human-readable landing page.

**Outcome:** for every user, a base64 subscription file and an HTML page under `subscription_root`, named after a token derived from `vault_seed`.
**Idempotent:** yes — same seed and same roster produce byte-identical files.
**Atomic:** no; users are rendered one at a time.
**Rollback:** files are backed up on change (`backup: true`). Revoking access means removing the user from the roster and re-running — the old file is not deleted automatically, so delete it from `subscription_root` as well.

No backend: nothing to exploit, nothing to monitor, and every angie node serves the identical set.

## What lands in a user's file

One entry per (chain, ALPN). A chain is addressed at the node that fronts it — its `via` — because that is where the user's TLS terminates; what happens after that is the server's business, and nothing in the link describes it. Labels carry the chain name and the ALPN, so a user reporting "v0-v3-h3 is slow" is naming something you can act on.

Which chains a user gets follows from `subscription_tier_kinds`. That policy is enforced twice: here, by leaving the links out, and in the `xray` role, by leaving the UUID out of the inbound. The second one is the one that matters — the first is convenience.

## Pending chains are not published

`subscription_chains` defaults to `vpn_chains_ready`, which excludes any chain touching an unmanaged node. Such a chain has nothing listening on the path it would dial, so publishing it would hand out a link that cannot work. It appears in subscriptions the run after that node is taken over.

## Names are labels

`name` identifies a user to the deployment and nothing more: it derives their UUID and token, and tags them in xray's config. It is not a person's name, and should not be — the label lands in clear text on every node. Who is behind `u-a` is yours to remember.

## The filename is the credential

The token in the path *is* the user's access. That is why `subscription_show_links` defaults to `false` — printing a link writes a credential into the run log and into any CI system that captures it.

The links are reproducible from the seed at any time, so nothing is lost by keeping them out of the log:

```bash
ansible-playbook site.yml --tags subscription -v \
  -e subscription_show_links=true --ask-vault-pass
```

## Requirements

* `vault_seed` from the vault.
* The inventory must define `vpn_chains_ready`, `vpn_chain_data`, `vpn_sub_prefix` and `vpn_domains` for every host fronting a chain, because `sub.txt.j2` reads them across plays through `hostvars`.
* `subscription_root` must match `angie_sub_root`.

## Variables

Full specification with types and defaults: [`meta/argument_specs.yml`](meta/argument_specs.yml).

| Variable | Default | Purpose |
|---|---|---|
| `subscription_users` | `{{ vpn_users }}` | Roster of `{name, tier, rot}` |
| `subscription_tier_kinds` | `{{ vpn_tier_kinds }}` | Which chain kinds each tier may use |
| `subscription_chains` | `{{ vpn_chains_ready }}` | Chains to publish |
| `subscription_chain_data` | `{{ vpn_chain_data }}` | Per-chain kinds and paths |
| `subscription_alpns` | `[h2, h3]` | One link per ALPN per chain |
| `subscription_page_lang` | `en` | Selects `templates/index.<lang>.html.j2` |
| `subscription_show_links` | `false` | Whether to print the links during the run |
| `subscription_root` | `/var/www/sub` | Where payloads are written |
| `subscription_domain` | `{{ vpn_domain }}` | Domain the subscription URL itself points at |
| `subscription_prefix` | `{{ vpn_sub_prefix }}` | Secret path prefix angie serves under |
| `subscription_update_interval` | `12` | Refresh hint for clients, in hours |

## Example

```yaml
- name: Publish subscriptions
  ansible.builtin.import_role:
    name: subscription
  vars:
    subscription_page_lang: ru
```

## Adding a language

Add `templates/index.<lang>.html.j2` and set `subscription_page_lang`. Everything else in this repository is English; this is the one string set your end users actually read.

## Known gap

`Subscription-Userinfo` is not populated. Doing so needs the xray stats API and a small collector.
