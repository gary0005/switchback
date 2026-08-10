# firewall

Default-drop nftables ruleset whose open ports follow from the node's place in the topology.

**Outcome:** `/etc/nftables.conf` holds a ruleset that drops everything inbound except established traffic, ICMP, SSH, and whatever this node's groups justify; nftables is enabled and running.
**Idempotent:** yes. The ruleset is validated with `nft -c -f` before it is written, and the reload handler only fires when the file actually changed.
**Atomic:** yes — `flush ruleset` plus the new table is applied in one `nft -f`.
**Rollback:** the previous ruleset is backed up on change (`backup: true`). Restore it and run `nft -f /etc/nftables.conf`.

## What gets opened

| Condition | Rule |
|---|---|
| always | established/related, loopback, ICMP and ICMPv6 |
| always | SSH, restricted to `firewall_ssh_allowed_cidrs` when that list is non-empty |
| member of a group in `firewall_ingress_groups` | TCP 80 and 443, UDP 443 for HTTP/3 |
| member of `firewall_peer_group`, with at least one peer | `firewall_relay_port`, source-restricted to the other peers' addresses |

A node outside `firewall_peer_group` can never reach the relay port. That is what makes "domestic egress hits angie only" structural rather than a matter of operator discipline.

## Variables

Full specification with types and defaults: [`meta/argument_specs.yml`](meta/argument_specs.yml).

| Variable | Default | Purpose |
|---|---|---|
| `firewall_ssh_allowed_cidrs` | `[]` | Source ranges allowed to reach SSH; empty leaves 22 open |
| `firewall_ssh_port` | `22` | Port SSH listens on |
| `firewall_ingress_tcp_ports` | `[80, 443]` | TCP ports opened on ingress nodes |
| `firewall_ingress_udp_ports` | `[443]` | UDP ports opened on ingress nodes |
| `firewall_peer_group` | `eu` | Group whose members may reach each other's relay port |
| `firewall_ingress_groups` | `[edge, ru]` | Groups whose members take user traffic |
| `firewall_relay_port` | `{{ vpn_relay_port }}` | Port the xray relay listens on |
| `firewall_config_file` | `/etc/nftables.conf` | Path of the rendered ruleset |
| `firewall_required_facts` | `[os_family]` | Facts gathered if the play sets `gather_facts: false` |

## Example

```yaml
- name: Configure the firewall
  ansible.builtin.import_role:
    name: firewall
  vars:
    firewall_ssh_allowed_cidrs:
      - 203.0.113.0/24
```

## Known gap

The peer set is IPv4 only. An IPv6 counterpart to the `eu_peers` set is still missing, so a peer reachable only over IPv6 would be dropped.
