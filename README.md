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

## Layout

```
inventory/
├── hosts.yml                    group and host membership only, no variables
├── group_vars/all/
│   ├── ansible.yml              connection settings
│   ├── main.yml                 seed-derived deployment data and settings
│   └── vault.yml                encrypted; vault_seed and provider credentials
└── host_vars/<host>/main.yml    ansible_host and public_domain
roles/<role>/
├── defaults/main.yml            the role's interface, with defaults
├── meta/argument_specs.yml      validated at role start; fails fast on typos
└── README.md                    variables, example, idempotency, rollback
```

### Variable naming

| Prefix | Meaning |
|---|---|
| `<role>_*` | Input to that role. Declared in its `defaults/main.yml`, validated by its `argument_specs.yml`. |
| `vpn_*` | Deployment-wide data shared by more than one role, and anything read for *another* host through `hostvars`. |
| `__*` | Internal to a role — registered results, computed facts. Not part of any interface. |

The `vpn_*` layer is not decoration. Role defaults are only in scope for hosts of the running play, so a value read for a peer in a different play — an exit node's Reality short ID, an edge node's XHTTP path — has to live in the inventory or it comes back undefined.

## Usage

```bash
ansible-galaxy collection install -r requirements.yml
pip install pre-commit && pre-commit install

# 1. Fill in node addresses and domains
$EDITOR inventory/hosts.yml               # membership
$EDITOR inventory/host_vars/edge1/main.yml  # ansible_host, public_domain

# 2. Set the notification address for Let's Encrypt
$EDITOR inventory/group_vars/all/main.yml   # acme_email has no default

# 3. Create the vault (vault_seed = openssl rand -hex 32)
cp inventory/group_vars/all/vault.yml.example /tmp/vault.yml
$EDITOR /tmp/vault.yml
ansible-vault encrypt --output inventory/group_vars/all/vault.yml /tmp/vault.yml
shred -u /tmp/vault.yml

# 4. Seed known_hosts — host key checking is on, verify these out of band
ssh-keyscan -H 203.0.113.10 >> ~/.ssh/known_hosts

# 5. DNS — records must resolve before certificates are issued
cd terraform && terraform init && terraform apply && cd ..

# 6. Deploy
ansible-playbook site.yml --ask-vault-pass
```

## Day-to-day operations

| Task | Action |
|---|---|
| Add a user | one line under `vpn_users:` in `group_vars/all/main.yml`, then `--tags users` |
| Revoke access | remove the line, re-run with `--tags users`, delete the stale file from `/var/www/sub` |
| Reissue one user's UUID and link | set `rot: 2` for that user, then `--tags users` |
| Change a user's tier | `tier: main` to `tier: all` and back, then `--tags users` |
| Rotate every path and port | change `vault_seed` |
| Change a domain | edit `host_vars/<host>/main.yml` and `terraform/terraform.tfvars` |
| Change provider | edit `ansible_host`; roles are untouched |
| Print subscription links | `--tags subscription -v -e subscription_show_links=true` |

### Tags

Each role can be run or skipped by its own name. Two purpose tags are complete on their own: `users` refreshes everything depending on the roster (xray's client lists and the subscription files), `certs` requests or renews certificates.

## Security notes

**Subscription links are credentials.** The token in the path *is* the access, so links are not printed during a run unless you ask with `subscription_show_links=true`. They stay reproducible from the seed, so nothing is lost by keeping them out of your shell history and CI logs.

**Host key checking is on.** Disabling it would accept any key on first connection, which hands an on-path attacker a root shell on the nodes this repository exists to keep private. Seed `known_hosts` from a channel you trust.

**Pin the downloads.** `xray_archive_checksum` and `angie_repo_key_checksum` are empty by default, which means those artefacts are fetched unverified — and the xray binary runs as root. Fill both in; see the [xray role README](roles/xray/README.md).

**Never commit an unencrypted vault.** `pre-commit install` wires up `detect-secrets` and `gitleaks`; the same checks run in CI.

## Localisation

Everything in this repository is English except the user-facing subscription page, which ships in two variants selected by `subscription_page_lang` (`en` by default). Add `roles/subscription/templates/index.<lang>.html.j2` for another language.

## Things that will break it

**Use `mode: packet-up`, not `auto`.** Under HTTP/3, `auto` selects `stream-one`, which needs full-duplex to the upstream — angie does not guarantee that over HTTP/1.1, and the connection hangs with no useful error.

**`proxy_buffering off` and `proxy_request_buffering off`.** Without them angie accumulates the stream in a buffer instead of forwarding it. Same symptom: it hangs.

**`client_max_body_size 0`.** XHTTP sends bodies of unknown length; the default 1M ceiling tears the upload stream on the first sizeable request.

**`PrivateTmp=no` in the xray unit.** With `PrivateTmp=yes`, systemd namespaces both `/dev/shm` and `/tmp`, and angie stops seeing the unix socket.

**Clock accuracy.** Reality and VLESS both depend on it; a couple of minutes of drift breaks the handshake. `chrony` is installed by the `common` role for that reason, not for tidiness.

**A non-empty document root.** The decoy under `/var/www/decoy` is not a decoration — a domain serving nothing at `/` fails the first active probe.

## Testing

```bash
pre-commit run --all-files      # yamllint, ansible-lint, secret scanning
ansible-playbook site.yml --syntax-check
ansible-playbook site.yml --check --diff --ask-vault-pass
```

Every role supports check mode. Tasks that only read — the version probe, the Reality key derivation, `angie -t` — carry `check_mode: false` so their results are still registered under `--check`; without that the templates downstream would fail on undefined keys.

There is no Molecule coverage yet. See "Known gaps".

## Known gaps

* No Molecule scenarios. Idempotency is only verified by re-running the playbook by hand.
* nftables rules are IPv4 only; `eu_peers` needs an IPv6 counterpart.
* No monitoring. Angie can expose `/status` as JSON — worth wiring up a node_exporter and an alert on certificate expiry.
* `Subscription-Userinfo` is not populated; doing so needs the xray stats API and a small collector.
* `xray x25519 -i` output has changed between major versions (`Public key:` became `Password:`). The parser handles both, but a third variant would not be caught immediately — check this after upgrading xray.
* Revoking a user does not delete their already-rendered subscription file; remove it from `/var/www/sub` by hand.

## License

MIT.
