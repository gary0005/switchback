# switchback

Ansible that builds a multi-hop Xray deployment fronted by Angie (h2 + h3). DNS is maintained by hand at the registrar; the `verify` role asserts it still matches the inventory. Everything else must be reproducible from this repo.

## Hard rules

1. **Never commit a real domain, IP, token or personal detail — an email address included.** Committed files use RFC 5737 addresses and `example.com`. Real values live in the gitignored `inventory/host_vars/<host>/main.yml`, beside a committed `main.yml.example`, or in the vault (`vault_seed`, `vault_acme_email`, `vault_dns_zone`, `vault_spaceship_api_*`). When adding a node, write both files. When a role needs a personal value, bridge it in `group_vars/all/main.yml` as `<role>_x: "{{ vault_x }}"` rather than inlining it.
2. **User names in `vpn_users` are labels, never people.** They are written in clear text into xray's config on every node, so the vault would hide them from this repository and from nowhere else. They also feed the UUID and token derivation, so renaming one reissues that user's access.
3. **Never touch a node in the `unmanaged` group.** It carries live user traffic under someone else's configuration. Plays exclude it by targeting `vpn:!unmanaged`, so the exclusion is structural rather than a matter of operator memory. Its peers still read its domains and chain paths from the inventory.
4. **No traffic ever reaches xray directly from the network.** xray binds unix sockets only; angie on 443 is the single ingress, and node-to-node hops speak the same VLESS+XHTTP/TLS/443 an ordinary client speaks. Any change that opens an xray port is wrong — the censor bans direct xray flows fast.
5. **Nothing lives in state.** Paths, ports, UUIDs, tokens all derive from `vault_seed` via `hash('sha256')` / `to_uuid`. No fact cache, no cross-host `delegate_to`, no play ordering — any play must run under `--limit`. (The acme role delegates to *localhost*, which is a different thing: it is where certbot and the DNS key live, and it depends on no other node.)

## Variable naming

| Prefix | Meaning |
|---|---|
| `<role>_*` | Role input. In `defaults/main.yml`, validated by `meta/argument_specs.yml`. |
| `vpn_*` | Deployment-wide, read for *other* hosts through `hostvars`. |
| `__*` | Role-internal: registered results, computed facts. |

**Role defaults are not in `hostvars` for a host in another play.** Anything read for a peer — another node's domain, a chain's transit path — must be a `vpn_*` name defined in inventory `group_vars`, or it comes back undefined. This is the single most common bug here.

## Config gotchas that cost hours

- XHTTP needs `mode: packet-up`. `auto` picks `stream-one`, which wants full duplex to the upstream; angie does not guarantee that over HTTP/1.1 and the stream hangs with no error.
- angie: `proxy_buffering off`, `proxy_request_buffering off`, `client_max_body_size 0`. Missing any of the three → hangs or torn uploads.
- `reuseport` may appear only **once per address:port** across all server blocks. With more than one `server {}` on 443, only the first carries it.
- xray unit needs `PrivateTmp=no`, or angie stops seeing the unix socket.
- `chrony` is mandatory: VLESS breaks on minutes of clock drift.
- A document root that serves nothing at `/` fails the first active probe.
- certbot: use `--cert-name` when a cert covers several names, otherwise adding a SAN silently does nothing (the `creates:` guard still matches).
- A Jinja comment or tag directly after `{{ ansible_managed | comment }}` eats the newline it ends on and comments out the first real line. Keep computation and explanation above it.
- dns-01 is answered by `roles/acme/templates/dns-hook.sh.j2`, a hook in this repo rather than a third-party plugin, running on the controller beside certbot. `PUT /v1/dns/records/{zone}` is **additive** on this API; do not "read, modify, write" or you will replace the zone. Names are relative to it: apex is `_acme-challenge`, a subdomain is `_acme-challenge.<sub>`.
- The hook polls until its TXT is visible and exits non-zero if it never is. Never replace that with a fixed sleep: a challenge checked too early is a failed issue and a spent rate-limit slot.
- acme runs before angie, which will not start without a certificate. dns-01 needs nothing from angie, so keep it that way — no placeholder, no symlink, no second pass.
- **The DNS credential never goes on a node.** It is account-wide at the registrar and cannot be scoped down, so certbot runs on the controller (`delegate_to: localhost`, `become: false`, under `acme_local_dir`) and nodes get only the two PEM files. `verify` fails if such a key appears on a node — do not "simplify" by moving issuing back onto them.
- The price of that is renewal only happening when the playbook runs. `acme_renew_days` is 45 for slack; do not lower it without adding something that watches expiry.

## Tooling

- Use the **ansible-know** MCP for module/collection docs and CoP practice, **context7** for Angie, certbot and Xray. Check before writing rather than trusting recall; these move.
- Ansible runs from `.venv/` (gitignored) via `uv run`.

## Checks before saying it works

```bash
pre-commit run --all-files
ansible-playbook site.yml --syntax-check
ansible-playbook site.yml --check --diff --ask-vault-pass
ansible-playbook site.yml --tags verify --ask-vault-pass
```

The `verify` role is the one that decides whether a change actually worked: it asserts xray holds no network listener and that every chain exits through the node it names. Run it after touching topology, angie or xray. To check templates without hosts, render them locally with a throwaway playbook that pulls the role `defaults/main.yml` in through `vars_files`.

Tasks that only read (version probe, key derivation, `angie -t`) carry `check_mode: false`, or the templates downstream fail on undefined keys in `--check`. Keep that when adding read-only tasks.

`ansible-lint` runs the `production` profile. Every role needs `meta/argument_specs.yml` and a README covering variables, an example, idempotency and rollback — match the existing ones.

## Style

- English everywhere except `roles/subscription/templates/index.<lang>.html.j2`.
- Comments explain *why*, not *what*; the existing files set the density. Do not add a comment that restates the task name.
- JSON templates build lists in Jinja and pipe them through `to_json` — never hand-assemble JSON with commas in a loop.
- Group names are role parameters, not literals, so one role can describe more than one topology.

# Git workflow
- One commit per logical unit of work.
- Commit messages — in English. Follow conventional commits standard.
- **Commit to `main`. Never create a branch unless asked for one.** One person works on this repository, so a branch buys no review and costs a merge on every change. If something is risky enough to want isolating, say so and ask — do not decide it by branching.
