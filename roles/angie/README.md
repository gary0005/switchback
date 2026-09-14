# angie

Angie fronting xray on 443, over both TCP (h2) and QUIC (h3).

**Outcome:** angie terminates user TLS for every name the node answers to, proxies the chain paths to xray over unix sockets, serves the subscription directory under a secret prefix, and answers everything else with the public site.
**Idempotent:** yes. The configuration is checked with `angie -t` on every run, and reloads only fire when a config file actually changed.
**Atomic:** no.
**Rollback:** every rendered file is backed up on change (`backup: true`). Restore and `systemctl reload angie`.

## One server block, several names

`angie_domains` holds the node's primary name plus its aliases, such as the apex. They are all served by a single `server` block, which is also what keeps `reuseport` legal: it may appear only once per address:port across the whole configuration, and a second block on 443 would have to omit it. Omitting it silently is how you end up debugging QUIC.

The apex may point at several nodes at once, and each of them serves it. That works because certificates come over dns-01 — ownership is proven by a TXT record, not by being the node a name resolves to — and they are issued on the controller, so no node holds the key that writes it. See the [acme role](../acme/README.md).

## One location per path

angie publishes a location for the user-facing path of every chain the node fronts, and for the transit path of every chain it terminates. Both are rendered from the same template with the same proxy settings, because a request arriving from a peer node must not be distinguishable from a user's — same port, same ALPN, same certificate, same everything on the wire.

## Requirements

* The `acme` role must have installed a certificate covering every name in `angie_domains` into `angie_cert_dir`. angie will not start without it, which is why acme runs first — issuing happens on the controller and needs nothing from angie, so there is no ordering problem.
* The `xray` role owns `angie_socket_dir`; angie only reads from it. Run xray first, or every location returns 502 until the next run.
* `angie_sub_root` must match `subscription_root`, and `angie_site_root` must match `website_root`.

## Variables

Full specification with types and defaults: [`meta/argument_specs.yml`](meta/argument_specs.yml).

| Variable | Default | Purpose |
|---|---|---|
| `angie_domains` | `{{ vpn_domains }}` | Every name TLS is terminated for |
| `angie_cert_name` | `{{ inventory_hostname }}` | Certificate lineage, matching `acme_cert_name` |
| `angie_cert_dir` | `/etc/ssl/switchback/<name>` | Where acme installs the files; must match `acme_node_cert_dir` |
| `angie_chains` | `{{ vpn_chains }}` | Chain declaration; decides which locations exist |
| `angie_chain_data` | `{{ vpn_chain_data }}` | Per-chain paths |
| `angie_socket_dir` | `{{ vpn_socket_dir }}` | Where xray's unix sockets live |
| `angie_sub_prefix` | `{{ vpn_sub_prefix }}` | Secret prefix subscriptions are served under |
| `angie_site_root` | `/var/www/site` | Document root of the public site |
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

**`http3 on` and the `Alt-Svc` header.** Clients only try h3 once they have been told it exists.

**A non-empty document root.** The site under `angie_site_root` is not decoration — a domain serving nothing at `/` fails the first active probe.

**Access logging stays off.** A node should not retain a record of who passed through it and when.

## Why `angie -t` is a separate task

The `validate:` parameter of `ansible.builtin.template` checks the temporary file, which `angie.conf` does not include yet — so it would always pass. The check is run as its own task against the installed configuration instead.
