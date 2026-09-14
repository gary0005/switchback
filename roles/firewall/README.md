# firewall

Default-drop nftables ruleset. Every node gets the same one.

**Outcome:** `/etc/nftables.conf` holds a ruleset that drops everything inbound except established traffic, ICMP, SSH and the web ports; nftables is enabled and running.
**Idempotent:** yes. The ruleset is validated with `nft -c -f` before it is written, and the reload handler only fires when the file actually changed.
**Atomic:** yes — `flush ruleset` plus the new table is applied in one `nft -f`.
**Rollback:** the previous ruleset is backed up on change (`backup: true`). Restore it and run `nft -f /etc/nftables.conf`.

## What gets opened

| Condition | Rule |
|---|---|
| always | established/related, loopback, ICMP and ICMPv6 |
| always | SSH, restricted to `firewall_ssh_allowed_cidrs` when that list is non-empty |
| always | TCP 80 and 443, UDP 443 for HTTP/3 |

That is the complete list, and it is the same on every node. There is no port for xray and no exception for peers: xray binds unix sockets, and the second leg of a two-hop chain arrives on 443 like any user's session. "Nothing reaches xray directly" therefore holds by construction rather than by operator discipline — and the `verify` role asserts it on every run.

The rules are family-agnostic, so IPv6 ingress is covered by the same lines as IPv4.

## Variables

Full specification with types and defaults: [`meta/argument_specs.yml`](meta/argument_specs.yml).

| Variable | Default | Purpose |
|---|---|---|
| `firewall_ssh_allowed_cidrs` | `[]` | Source ranges allowed to reach SSH; empty leaves 22 open |
| `firewall_ssh_port` | `22` | Port SSH listens on |
| `firewall_ingress_tcp_ports` | `[80, 443]` | TCP ports opened on every node |
| `firewall_ingress_udp_ports` | `[443]` | UDP ports opened on every node |
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

## If you are about to add a port here

Adding one means something has started listening that is not angie. Check what it is before changing this file — the `verify` role will fail on the new port, and that failure is the feature.
