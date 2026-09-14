# common

Baseline every node gets, whatever part it plays: packages, clock synchronisation, and the sysctl tuning BBR and QUIC depend on.

**Outcome:** the node has a synchronised clock, BBR queueing, UDP buffers large enough for HTTP/3, and unattended security upgrades enabled.
**Idempotent:** yes. **Atomic:** no — package installation and sysctl tuning are independent steps.
**Rollback:** none built in. The sysctl drop-in and the apt periodic file are backed up on change (`backup: true`), so the previous version is recoverable on the host; removing the drop-in and running `sysctl --system` reverts the tuning.

Packages needed by exactly one other role are installed by that role — `nftables` by `firewall`, `unzip` by `xray` — so every role can be run on its own.

## Variables

Full specification with types and defaults: [`meta/argument_specs.yml`](meta/argument_specs.yml).

| Variable | Default | Purpose |
|---|---|---|
| `common_base_packages` | see specs | Packages installed on every node |
| `common_time_sync_service` | `chrony` | Service kept running to hold the clock steady |
| `common_sysctl_file` | `/etc/sysctl.d/99-vpn.conf` | Path of the rendered drop-in |
| `common_unattended_upgrades_enabled` | `true` | Whether security upgrades apply themselves |
| `common_socket_buffer_max` | `16777216` | `net.core.{r,w}mem_max` |
| `common_file_max` | `1000000` | `fs.file-max` |
| `common_required_facts` | `[os_family]` | Facts gathered if the play sets `gather_facts: false` |

## Example

```yaml
- name: Apply base system configuration
  ansible.builtin.import_role:
    name: common
  vars:
    common_unattended_upgrades_enabled: false
```

## Why the clock matters

VLESS fails the handshake on more than a couple of minutes of drift. `chrony` is installed here for that reason, not for tidiness — clock drift is the most common cause of "everything suddenly stopped working".
