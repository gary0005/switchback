# switchback

Ansible for a multi-hop [Xray](https://github.com/XTLS/Xray-core) deployment fronted by [Angie](https://angie.software/) over HTTP/3. Three routing chains — one hop for testing, two hops for normal use, three hops when the first leg has to terminate inside a restricted network. Terraform is used for DNS only.

## Topology

```
1 hop     client ──TLS443──> edge ─────────────────────> internet
2 hops    client ──TLS443──> edge ··reality:random··> exit ──> internet
3 hops    client ──TLS443──> entry ──TLS443──> edge ··reality··> exit ──> internet
```

* Users always arrive at angie on 443 — TCP for h2, QUIC for h3.
* The entry node is not a member of the `eu` group, so it never lands in the firewall's peer set and cannot reach xray directly. Its egress speaks the same XHTTP/443 an ordinary client speaks.
* Offshore nodes talk to each other over VLESS+Reality on a random port, open only to addresses in the `eu` group.

## How it works

**Nothing lives in state.** Paths, ports, UUIDs, Reality keys and subscription tokens are all derived from a single `vault_seed`. The repository is the only source of truth; the playbook is idempotent and reproducible from scratch.

**Reality keys are computed locally.** The private key is deterministic and the public key is derived from it by the `xray` binary, so an edge node can compute an exit node's key on its own. No `delegate_to`, no fact cache, no dependency on play ordering — any play can be run with `--limit` in isolation.

**Tiers are enforced server side.** A `tier: main` user does not merely lack the 3-hop configs in their subscription; their UUID is absent from that inbound's client list.

## Usage

```bash
ansible-galaxy collection install -r requirements.yml

# 1. Fill in node addresses and domains
$EDITOR inventory/hosts.yml

# 2. Create the vault (vault_seed = openssl rand -hex 32)
cp inventory/group_vars/all/vault.yml.example /tmp/vault.yml
$EDITOR /tmp/vault.yml
ansible-vault encrypt --output inventory/group_vars/all/vault.yml /tmp/vault.yml
shred -u /tmp/vault.yml

# 3. DNS — records must resolve before certificates are issued
cd terraform && terraform init && terraform apply && cd ..

# 4. Deploy
ansible-playbook site.yml --ask-vault-pass
```

Subscription links are printed at the end of the run.

## Day-to-day operations

| Task | Action |
|---|---|
| Add a user | one line under `users:` in `group_vars/all/main.yml` |
| Revoke access | remove the line, re-run the playbook |
| Reissue one user's UUID and link | set `rot: 2` for that user |
| Change a user's tier | `tier: main` to `tier: all` and back |
| Rotate every path and port | change `vault_seed` |
| Change a domain | edit `public_domain` and `terraform/terraform.tfvars` |
| Change provider | edit `ansible_host`; roles are untouched |

## Localisation

Everything in this repository is English except the user-facing subscription page, which ships in two variants selected by `sub_page_lang` (`en` by default). Add `roles/subscription/templates/index.<lang>.html.j2` for another language.

## Things that will break it

**Use `mode: packet-up`, not `auto`.** Under HTTP/3, `auto` selects `stream-one`, which needs full-duplex to the upstream — angie does not guarantee that over HTTP/1.1, and the connection hangs with no useful error.

**`proxy_buffering off` and `proxy_request_buffering off`.** Without them angie accumulates the stream in a buffer instead of forwarding it. Same symptom: it hangs.

**`client_max_body_size 0`.** XHTTP sends bodies of unknown length; the default 1M ceiling tears the upload stream on the first sizeable request.

**`PrivateTmp=no` in the xray unit.** With `PrivateTmp=yes`, systemd namespaces both `/dev/shm` and `/tmp`, and angie stops seeing the unix socket.

**Clock accuracy.** Reality and VLESS both depend on it; a couple of minutes of drift breaks the handshake. `chrony` is installed by the `common` role for that reason, not for tidiness.

**A non-empty document root.** The decoy under `/var/www/decoy` is not a decoration — a domain serving nothing at `/` fails the first active probe.

## Known gaps

* nftables rules are IPv4 only; `eu_peers` needs an IPv6 counterpart.
* No monitoring. Angie can expose `/status` as JSON — worth wiring up a node_exporter and an alert on certificate expiry.
* `Subscription-Userinfo` is not populated; doing so needs the xray stats API and a small collector.
* `xray x25519 -i` output has changed between major versions (`Public key:` became `Password:`). The parser handles both, but a third variant would not be caught immediately — check this after upgrading xray.

## License

MIT.
