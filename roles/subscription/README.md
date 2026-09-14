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

`subscription_chains` defaults to `vpn_chains_ready`, which excludes any chain touching an unmanaged node, and any chain marked `blocked: true` — one known not to carry traffic because something between those two nodes drops it. Such a chain has nothing listening on the path it would dial, so publishing it would hand out a link that cannot work. It appears in subscriptions the run after that node is taken over.

## Names are labels

`name` identifies a user to the deployment and nothing more: it derives their UUID and token, and tags them in xray's config. It is not a person's name, and should not be — the label lands in clear text on every node. Who is behind `u-a` is yours to remember.

## Links live under the shared apex

Every node renders the identical set of files, so the subscription URL names the apex rather than one node. A link naming a single node dies with that node; a link under the apex is answered by whichever one the round robin reaches.

The trade-off is worth knowing: if one of the nodes behind the apex is unreachable from a particular network, refreshing the subscription fails some of the time from there — the client retries and gets a different address. The configs inside the file are unaffected, since each names its own entry node directly.

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
| `subscription_page_langs` | `[en]` | Languages the page offers; first is the fallback |
| `subscription_show_links` | `false` | Whether to print the links during the run |
| `subscription_root` | `/var/www/sub` | Where payloads are written |
| `subscription_domain` | `{{ vpn_apex }}` | Domain the subscription URL points at — the shared apex |
| `subscription_prefix` | `{{ vpn_sub_prefix }}` | Secret path prefix angie serves under |
| `subscription_update_interval` | `12` | Refresh hint for clients, in hours |

## Example

```yaml
- name: Publish subscriptions
  ansible.builtin.import_role:
    name: subscription
  vars:
    subscription_page_langs: [ru, en]
```

## Adding a language

Add `templates/index.<lang>.html.j2` and name the language in `subscription_page_langs`. The file holds the body for that language and nothing else — [`templates/index.html.j2`](templates/index.html.j2) wraps it and computes `sub_url`, `n_multi` and `n_test` before including it.

Every configured language ships in the same file and the reader switches with a control on the page, so a language costs a few hundred bytes rather than a second file per user. A browser asking for one of them gets it without touching the switch, and a choice made on the page is remembered. Everything else in this repository is English; this is the one string set your end users actually read.

## Known gap

`Subscription-Userinfo` is not populated. Doing so needs the xray stats API and a small collector.
