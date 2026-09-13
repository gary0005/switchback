# switchback

Ansible that builds a multi-hop Xray deployment fronted by Angie (h2 + h3). Terraform handles DNS only. Everything must be reproducible from this repo.

## Hard rules

1. **Never commit a real domain, IP or token.** Inventory examples use RFC 5737 addresses and `example.com`. Real values live in a private overlay or the vault.
2. **Never touch the node marked `vpn_managed: false`.** It carries live user traffic. Plays must exclude it structurally, not by operator memory.
3. **No traffic ever reaches xray directly from the network.** xray binds unix sockets only; angie on 443 is the single ingress, and node-to-node hops speak the same VLESS+XHTTP/TLS/443 an ordinary client speaks. Any change that opens an xray port is wrong — the censor bans direct xray flows fast.
4. **Nothing lives in state.** Paths, ports, UUIDs, tokens all derive from `vault_seed` via `hash('sha256')` / `to_uuid`. No fact cache, no `delegate_to`, no play ordering — any play must run under `--limit`.

## Variable naming

| Prefix | Meaning |
|---|---|
| `<role>_*` | Role input. In `defaults/main.yml`, validated by `meta/argument_specs.yml`. |
| `vpn_*` | Deployment-wide, read for *other* hosts through `hostvars`. |
| `__*` | Role-internal: registered results, computed facts. |

**Role defaults are not in `hostvars` for a host in another play.** Anything read for a peer must be a `vpn_*` name defined in inventory `group_vars`, or it comes back undefined. This is the single most common bug here — see the existing `hostvars[item]['xray_reality_priv_hex']` in `roles/xray/tasks`.

## Config gotchas that cost hours

- XHTTP needs `mode: packet-up`. `auto` picks `stream-one`, which wants full duplex to the upstream; angie does not guarantee that over HTTP/1.1 and the stream hangs with no error.
- angie: `proxy_buffering off`, `proxy_request_buffering off`, `client_max_body_size 0`. Missing any of the three → hangs or torn uploads.
- `reuseport` may appear only **once per address:port** across all server blocks. With more than one `server {}` on 443, only the first carries it.
- xray unit needs `PrivateTmp=no`, or angie stops seeing the unix socket.
- `chrony` is mandatory: Reality and VLESS break on minutes of clock drift.
- A document root that serves nothing at `/` fails the first active probe.
- certbot: use `--cert-name` when a cert covers several names, otherwise adding a SAN silently does nothing (the `creates:` guard still matches).

## Tooling

- Use the **ansible-know** MCP for module/collection docs and CoP practice, **context7** for Angie, certbot, Xray and the Cloudflare provider. Check before writing; Angie and the Cloudflare provider both moved recently (Cloudflare v5 renamed `cloudflare_record` → `cloudflare_dns_record`, and `name` is now the FQDN).
- Ansible runs from `.venv/` (gitignored) via `uv run`.

## Checks before saying it works

```bash
pre-commit run --all-files
ansible-playbook site.yml --syntax-check
ansible-playbook site.yml --check --diff --ask-vault-pass
```

Tasks that only read (version probe, key derivation, `angie -t`) carry `check_mode: false`, or the templates downstream fail on undefined keys in `--check`. Keep that when adding read-only tasks.

`ansible-lint` runs the `production` profile. Every role needs `meta/argument_specs.yml` and a README covering variables, an example, idempotency and rollback — match the existing ones.

## Style

- English everywhere except `roles/subscription/templates/index.<lang>.html.j2`.
- Comments explain *why*, not *what*; the existing files set the density. Do not add a comment that restates the task name.
- JSON templates build lists in Jinja and pipe them through `to_json` — never hand-assemble JSON with commas in a loop.
- Group names are role parameters, not literals, so one role can describe more than one topology.
