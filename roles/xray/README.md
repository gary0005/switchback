# xray

Xray-core install, deterministic Reality keys, and the routing config matching the node's part in the topology.

**Outcome:** a pinned Xray-core binary at `xray_bin`, a `config.json` validated by `xray run -test` before it is written, and a running systemd unit.
**Idempotent:** yes. The installed version is read off the binary, so the download runs once per version bump; key derivation only reads and never reports a change.
**Atomic:** no — binary installation and configuration are separate steps.
**Rollback:** `config.json` and the unit file are backed up on change (`backup: true`). Pin `xray_version` back and re-run to downgrade the binary.

## How the Reality keys work

The private key is derived deterministically from `vault_seed`, and the public key is computed from it by the `xray` binary on the host. An edge node can therefore compute an exit node's public key locally — no `delegate_to`, no fact cache, no dependency on play ordering, and any play can be run with `--limit` in isolation.

Peer material is read through `hostvars` using the inventory-level `vpn_*` names. Role defaults are only in scope for hosts of the running play, so a peer belonging to a different play would come back undefined if those values lived in `defaults/main.yml`.

## Tiers

Tiers are enforced here, in the inbound client lists. A `tier: main` user does not merely lack the 3-hop config in their subscription — their UUID is absent from that inbound altogether.

## Requirements

* `vault_seed` from the vault.
* The inventory must define `vpn_reality_priv_hex`, `vpn_reality_short_id`, `vpn_relay_port`, `vpn_path_hop1`..`hop3` and `vpn_socket_dir` for every host, because they are read across plays.

## Variables

Full specification with types and defaults: [`meta/argument_specs.yml`](meta/argument_specs.yml).

| Variable | Default | Purpose |
|---|---|---|
| `xray_version` | `25.3.6` | Release to install |
| `xray_archive_checksum` | `""` | SHA256 of the release archive; **empty means unverified** |
| `xray_node_role` | derived from groups | Which config template applies: `exit`, `edge` or `ru` |
| `xray_peer_group` | `eu` | Offshore nodes that may reach each other |
| `xray_exit_group` | `exit` | Nodes egressing to the internet |
| `xray_entry_group` | `ru` | Domestic ingress nodes |
| `xray_edge_group` | `edge` | Nodes terminating user TLS |
| `xray_users` | `{{ vpn_users }}` | Roster of `{name, tier, rot}` |
| `xray_tier_hop1/2/3` | `{{ vpn_tier_hop* }}` | Which tiers may use which chain |
| `xray_reality_dest` | `www.microsoft.com:443` | Host Reality borrows its handshake from |
| `xray_bin` / `xray_dir` / `xray_share_dir` | see specs | Install paths |
| `xray_stage_dir` | `/var/cache/xray-install` | Root-owned staging area for the archive |
| `xray_required_facts` | `[os_family]` | Facts gathered if the play sets `gather_facts: false` |

## Example

```yaml
- name: Configure xray
  ansible.builtin.import_role:
    name: xray
  vars:
    xray_version: "25.3.6"
    xray_archive_checksum: "sha256:<digest from the release .dgst file>"
```

## Verify the download

`xray_archive_checksum` is empty by default, which means the archive is **not** verified — and the binary it contains runs as root. Take the SHA256 from the release's `.dgst` file and pin it:

```bash
curl -sL https://github.com/XTLS/Xray-core/releases/download/v25.3.6/Xray-linux-64.zip.dgst
```

## Known gap

`xray x25519 -i` changed its output between major versions (`Public key:` became `Password:`). The parser handles both; a third spelling would not be caught immediately, so check this after upgrading `xray_version`.
