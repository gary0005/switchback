# switchback

Ansible for a multi-hop [Xray](https://github.com/XTLS/Xray-core) deployment fronted by [Angie](https://angie.software/) over HTTP/2 and HTTP/3. Terraform is used for DNS only.

## Topology

```
one hop    client ──TLS443──> via ──> internet
two hops   client ──TLS443──> via ──TLS443──> exit ──> internet
```

Both legs are the same thing on the wire: VLESS+XHTTP inside TLS on 443, to a domain that serves a real site. The second one is not a tunnel between servers on some port of its own — it is another HTTPS session, indistinguishable from the first.

That is the whole design. Traffic that arrives directly at xray on a port of its own is what gets spotted and blocked, so there is no such port: **xray binds unix sockets only, angie owns 443, and the `verify` role fails the run if that ever stops being true.**

## Chains are data

Nodes have no classes. A chain says who takes the user's traffic and who egresses:

```yaml
vpn_chains:
  - { name: v0-v2, via: v0, exit: v2 }   # two hops
  - { name: v2-solo, via: v2, exit: v2 } # one hop, for testing
```

Everything else follows: the XHTTP paths, xray's inbounds and outbounds, angie's locations, the firewall, the subscriptions, the checks. A node fronts the chains it is the `via` of, terminates the chains it is the `exit` of, and commonly does both.

Adding a node is one entry in `hosts.yml`, one `host_vars` file, and the chains you want. No role knows the name of a node.

## How it works

**Nothing lives in state.** Paths, UUIDs and subscription tokens all derive from a single `vault_seed`. Both ends of a chain derive the same values from the chain's name independently, so there are no cross-host facts, no `delegate_to`, no play ordering — any play runs under `--limit` in isolation.

**Tiers are enforced server side.** A user whose tier excludes single-hop chains does not merely lack those links; their UUID is absent from those inbounds.

**Unmanaged nodes are excluded structurally.** A node in the `unmanaged` group is skipped by every play — it carries live traffic under someone else's configuration. Its peers still read its domain and paths out of the inventory, and chains touching it stay out of subscriptions until it is taken over, because nothing is listening at the far end yet.

## Layout

```
inventory/
├── hosts.yml                    group and host membership only, no variables
├── group_vars/all/
│   ├── ansible.yml              connection settings
│   ├── main.yml                 chains, seed-derived data, users, settings
│   └── vault.yml                encrypted; vault_seed and provider credentials
└── host_vars/<host>/
    ├── main.yml.example         committed; placeholder addresses and domains
    └── main.yml                 gitignored; the real ansible_host and vpn_domains
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
| `__*` | Internal to a role — registered results, computed facts. |

The `vpn_*` layer is not decoration. Role defaults are only in scope for hosts of the running play, so a value read for a peer — a chain's transit path, another node's domain — has to live in the inventory or it comes back undefined.

## Usage

```bash
pip install pre-commit && pre-commit install

# 1. Nodes and chains. The real host_vars are gitignored, so start from the
#    examples — the playbook will not run until every node has a main.yml.
for h in inventory/host_vars/*/; do cp "$h/main.yml.example" "$h/main.yml"; done
$EDITOR inventory/host_vars/*/main.yml      # ansible_host, vpn_domains
$EDITOR inventory/hosts.yml                 # membership, and what is unmanaged
$EDITOR inventory/group_vars/all/main.yml   # vpn_chains, vpn_users, acme_email

# 2. Create the vault (vault_seed = openssl rand -hex 32)
cp inventory/group_vars/all/vault.yml.example /tmp/vault.yml
$EDITOR /tmp/vault.yml
ansible-vault encrypt --output inventory/group_vars/all/vault.yml /tmp/vault.yml
shred -u /tmp/vault.yml

# 3. Seed known_hosts — host key checking is on, verify these out of band
ssh-keyscan -H 203.0.113.10 >> ~/.ssh/known_hosts

# 4. DNS — records must resolve before certificates are issued
cd terraform && terraform init && terraform apply && cd ..

# 5. Deploy
ansible-playbook site.yml --ask-vault-pass
```

The last play checks what the first one built: it asserts the node exposes nothing but angie, then dials every chain and compares where the traffic came out against where it was supposed to.

## Day-to-day operations

| Task | Action |
|---|---|
| Add a user | one line under `vpn_users:`, then `--tags users` |
| Revoke access | remove the line, re-run with `--tags users`, delete the stale file from `/var/www/sub` |
| Reissue one user's UUID and link | set `rot: 2` for that user, then `--tags users` |
| Change a user's tier | `tier: main` to `tier: all` and back, then `--tags users` |
| Add a chain | one entry under `vpn_chains:`, then a full run |
| Add a node | `hosts.yml`, `host_vars/<host>/main.yml`, its chains, a DNS record |
| Take over an unmanaged node | remove it from the `unmanaged` group, run, then `--tags users` |
| Rotate every path and token | change `vault_seed` |
| Change a domain | edit `host_vars/<host>/main.yml` and `terraform/terraform.tfvars` |
| Check without changing | `--tags verify` |
| Print subscription links | `--tags subscription -v -e subscription_show_links=true` |

### Tags

Each role can be run or skipped by its own name. Three purpose tags are complete on their own: `users` refreshes everything depending on the roster, `certs` requests or renews certificates, `verify` checks a node without changing it.

## Security notes

**Subscription links are credentials.** The token in the path *is* the access, so links are not printed during a run unless you ask with `subscription_show_links=true`. They stay reproducible from the seed, so nothing is lost by keeping them out of your shell history and CI logs.

**Host key checking is on.** Disabling it would accept any key on first connection, which hands an on-path attacker a root shell on the nodes this repository exists to keep private. Seed `known_hosts` from a channel you trust.

**Never commit an unencrypted vault.** `pre-commit install` wires up `detect-secrets` and `gitleaks`; the same checks run in CI.

**Domains are not secrets, but they are not public either.** Everything committed here uses `example.com` and RFC 5737 addresses: real addresses and domains live in `host_vars/<host>/main.yml`, which is gitignored, next to the committed `main.yml.example`. Back those files up somewhere — they are not in the repository, and losing them means reconstructing the inventory by hand.

## Localisation

Everything in this repository is English except the user-facing subscription page, which ships in two variants selected by `subscription_page_lang` (`en` by default). Add `roles/subscription/templates/index.<lang>.html.j2` for another language.

## Things that will break it

**Use `mode: packet-up`, not `auto`.** Under HTTP/3, `auto` selects `stream-one`, which needs full-duplex to the upstream — angie does not guarantee that over HTTP/1.1, and the connection hangs with no useful error.

**`proxy_buffering off` and `proxy_request_buffering off`.** Without them angie accumulates the stream in a buffer instead of forwarding it. Same symptom: it hangs.

**`client_max_body_size 0`.** XHTTP sends bodies of unknown length; the default 1M ceiling tears the upload stream on the first sizeable request.

**`reuseport` only once per address:port.** It lives in the single 443 server block. A second server block on 443 must omit it, which is why every name a node answers to shares one block.

**`PrivateTmp=no` in the xray unit.** With `PrivateTmp=yes`, systemd namespaces both `/dev/shm` and `/tmp`, and angie stops seeing the unix socket.

**Clock accuracy.** VLESS depends on it; a couple of minutes of drift breaks the handshake. `chrony` is installed by the `common` role for that reason, not for tidiness.

**A non-empty document root.** The site under `/var/www/site` is not a decoration — a domain serving nothing at `/` fails the first active probe.

**A Jinja comment straight after `ansible_managed`.** It eats the newline the comment block ends on and comments out the first real line of the file. Keep computation and explanation above it.

## Testing

```bash
pre-commit run --all-files      # yamllint, ansible-lint, secret scanning
ansible-playbook site.yml --syntax-check
ansible-playbook site.yml --check --diff --ask-vault-pass
ansible-playbook site.yml --tags verify --ask-vault-pass
```

Every role supports check mode. Tasks that only read — the version probe, the certificate SAN read, `angie -t` — carry `check_mode: false` so their results are still registered under `--check`; without that the templates downstream would fail on undefined keys. The live chain checks are skipped under `--check`, which cannot run a client.

There is no Molecule coverage yet. See "Known gaps".

## Known gaps

* No Molecule scenarios. Idempotency is only verified by re-running the playbook by hand.
* `Subscription-Userinfo` is not populated; doing so needs the xray stats API and a small collector.
* Revoking a user does not delete their already-rendered subscription file; remove it from `/var/www/sub` by hand.
* The `website` role adds and updates files but does not prune ones deleted from the source.
* No monitoring beyond `--tags verify` on demand. Angie can expose `/status` as JSON — worth wiring up a node_exporter and an alert on certificate expiry.
* The live check leans on an external echo service (`verify_echo_url`) to learn the egress address.

## License

MIT.
