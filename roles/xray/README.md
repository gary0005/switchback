# xray

Xray-core install and the routing config implied by the chains that name this node.

**Outcome:** a pinned Xray-core binary at `xray_bin`, a `config.json` validated by `xray run -test` before it is written, and a running systemd unit.
**Idempotent:** yes. The installed version is read off the binary, so the download runs once per version bump.
**Atomic:** no — binary installation and configuration are separate steps.
**Rollback:** `config.json` and the unit file are backed up on change (`backup: true`). Pin `xray_version` back and re-run to downgrade the binary.

## Nodes have no classes

There is one template for every node. What a node does follows from the chain list: it fronts the chains it is the `via` of, terminates the chains it is the `exit` of, and a node commonly does both. Adding a node changes the inventory and nothing here.

For each chain naming this node, the config grows:

| Chain names this node as | Inbound | Routed to |
|---|---|---|
| `via`, and `via != exit` | `in-<chain>` on `<chain>-in.sock` | `out-<chain>`, dialling the exit node |
| `via`, and `via == exit` | `in-<chain>` on `<chain>-in.sock` | `direct` |
| `exit`, and `via != exit` | `transit-<chain>` on `<chain>-transit.sock` | `direct` |

## Nothing binds a port

Every inbound listens on a unix socket in `xray_socket_dir`; angie owns 443 and proxies into them. The second leg of a two-hop chain is a VLESS+XHTTP outbound over TLS to the far node's **443**, so it arrives at that node's angie exactly like a user's session would — same port, same ALPN, same certificate, a domain that serves a real site.

That is the point. Traffic arriving directly at xray on a port of its own is what gets spotted and blocked; there is no such port here, and the `verify` role asserts there never will be. The systemd unit drops `CAP_NET_BIND_SERVICE` for the same reason — if a config needs it back, that config is binding a port.

## Tiers

Tiers are enforced here, in the inbound client lists. A user whose tier does not cover a chain's kind has no UUID in that inbound at all — not merely a missing link in their subscription file.

The probe identity (`xray_probe_uuid`) is added to every user-facing inbound, so the `verify` role exercises the same inbound users do rather than a parallel one that could drift out of step with it.

## Requirements

* `vault_seed` from the vault.
* The inventory must define `vpn_chains`, `vpn_chain_data`, `vpn_socket_dir`, `vpn_probe_uuid` and, for every host named in a chain, `vpn_domains` — they are read across plays through `hostvars`, where role defaults are not in scope.

## Variables

Full specification with types and defaults: [`meta/argument_specs.yml`](meta/argument_specs.yml).

| Variable | Default | Purpose |
|---|---|---|
| `xray_version` | `26.3.27` | Release to install |
| `xray_archive_checksum` | pinned SHA256 | Verifies the archive; **update it with the version** |
| `xray_chains` | `{{ vpn_chains }}` | The full chain declaration, pending ones included |
| `xray_chain_data` | `{{ vpn_chain_data }}` | Per-chain paths, kinds and transit credentials |
| `xray_users` | `{{ vpn_users }}` | Roster of `{name, tier, rot}` |
| `xray_tier_kinds` | `{{ vpn_tier_kinds }}` | Which chain kinds each tier may use |
| `xray_probe_uuid` | `{{ vpn_probe_uuid }}` | Identity the `verify` role dials with |
| `xray_freedom_domain_strategy` | `UseIPv4` | Egress DNS behaviour on exit nodes |
| `xray_transit_alpn` | `[h2]` | ALPN of the node-to-node leg |
| `xray_socket_dir` | `{{ vpn_socket_dir }}` | Where the inbound sockets live |
| `xray_bin` / `xray_dir` / `xray_share_dir` | see specs | Install paths |
| `xray_stage_dir` | `/var/cache/xray-install` | Root-owned staging area for the archive |
| `xray_required_facts` | `[os_family]` | Facts gathered if the play sets `gather_facts: false` |

## Example

```yaml
- name: Configure xray
  ansible.builtin.import_role:
    name: xray
  vars:
    xray_version: "26.3.27"
    xray_archive_checksum: "sha256:<digest from the release .dgst file>"
```

## When you bump the version

The checksum is pinned, and the binary runs as root — so take the new digest from the release's `.dgst` file in the same edit:

```bash
curl -sL https://github.com/XTLS/Xray-core/releases/download/v26.3.27/Xray-linux-64.zip.dgst
```

`xray run -test -config` validates the rendered config before it replaces the running one, which catches a schema change in the release rather than letting it take the node down. Recent versions renamed `network` to `method` in `streamSettings` while keeping the old spelling working; if a future release drops it, that validation is where you will see it.

## Pending chains

A chain whose far end is an unmanaged node still gets its inbound and outbound here. It costs nothing, and it means taking that node over later touches only the node itself and the subscriptions — nothing on the nodes already running.
