# angie

Angie fronting xray on 443, over both TCP (h2) and QUIC (h3).

**Outcome:** angie terminates user TLS for the node's domain, proxies the XHTTP paths to xray over unix sockets, serves the subscription directory under a secret prefix, and answers everything else with a decoy page.
**Idempotent:** yes. The configuration is checked with `angie -t` on every run, and reloads only fire when a config file actually changed.
**Atomic:** no.
**Rollback:** every rendered file is backed up on change (`backup: true`). Restore and `systemctl reload angie`.

## Requirements

* The `acme` role must have placed a certificate for `angie_domain`.
* The `xray` role owns `angie_socket_dir`; angie only reads from it.
* `angie_sub_root` must match `subscription_root`.

## Variables

Full specification with types and defaults: [`meta/argument_specs.yml`](meta/argument_specs.yml).

| Variable | Default | Purpose |
|---|---|---|
| `angie_domain` | `{{ public_domain }}` | Name TLS is terminated for |
| `angie_edge_group` | `edge` | Members front hop1 and hop2; everything else fronts hop3 |
| `angie_socket_dir` | `{{ vpn_socket_dir }}` | Where xray's unix sockets live |
| `angie_sub_prefix` | `{{ vpn_sub_prefix }}` | Secret prefix subscriptions are served under |
| `angie_hop_paths` | derived | Chain name to XHTTP path |
| `angie_decoy_root` | `/var/www/decoy` | Document root for the decoy site |
| `angie_sub_root` | `/var/www/sub` | Directory the subscription role renders into |
| `angie_access_log` | `false` | Whether to keep an access log |
| `angie_client_max_body_size` | `0` | `client_max_body_size`; 0 disables the limit |
| `angie_proxy_timeout` | `300s` | Read and send timeout for XHTTP locations |
| `angie_repo_key_checksum` | `""` | SHA256 pinning the signing key; empty is trust-on-first-use |
| `angie_required_facts` | `[os_family, distribution, distribution_release]` | Facts gathered if the play sets `gather_facts: false` |

## Example

```yaml
- name: Configure angie
  ansible.builtin.import_role:
    name: angie
  vars:
    angie_access_log: false
    angie_repo_key_checksum: "sha256:<digest>"
```

## Settings that are not optional

**`proxy_buffering off` and `proxy_request_buffering off`.** Without them angie accumulates the stream in a buffer instead of forwarding it, and the connection hangs with no useful error.

**`client_max_body_size 0`.** XHTTP sends bodies of unknown length; the default 1M ceiling tears the upload stream on the first sizeable request.

**A non-empty document root.** The decoy under `angie_decoy_root` is not decoration — a domain serving nothing at `/` fails the first active probe.

**Access logging stays off.** A node should not retain a record of who passed through it and when.

## Why `angie -t` is a separate task

The `validate:` parameter of `ansible.builtin.template` checks the temporary file, which `angie.conf` does not include yet — so it would always pass. The check is run as its own task against the installed configuration instead.
