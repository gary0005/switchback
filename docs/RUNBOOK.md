# Runbook

Deploying this from nothing, and running it afterwards. Assumes you are
comfortable in a terminal and have not used Ansible before.

For what the deployment *is* and why it is shaped this way, read the
[README](../README.md) first. This file is the sequence of commands.

## How Ansible works here

Ansible is ssh plus templates. Nothing is installed on the nodes to support it:
you run `ansible-playbook` on your own machine, it connects to each node over
SSH and carries out a list of steps — install a package, write a file, restart a
service. Every step is written so it can run repeatedly; a second run changes
nothing unless the repository changed.

Three words you will meet:

| Term | Here |
|---|---|
| inventory | the nodes and their variables — [`inventory/`](../inventory/) |
| role | the steps for one thing: install xray, configure angie — [`roles/`](../roles/) |
| playbook | what runs where — [`site.yml`](../site.yml) |

One property matters more than the rest: **everything derives from one secret.**
Paths, user UUIDs and subscription tokens are not stored anywhere, they are
recomputed from `vault_seed` on every run. There is no state to lose — and no
way to change the seed without changing all of it at once.

## 1. Tooling

```bash
cd switchback
pip install pre-commit && pre-commit install
uv run ansible --version
```

Every command below is `uv run ansible-…`. `.venv/bin/ansible-…` is the same
thing if you prefer.

## 2. Reach the nodes

The roles connect as `root`, set in
[`inventory/group_vars/all/ansible.yml`](../inventory/group_vars/all/ansible.yml).
`ssh root@<node>` has to work with a key and no password. If your provider only
gives you an unprivileged user, switch that file to `become` instead.

Host key checking is deliberately on, so each node has to be in `known_hosts`
before Ansible will talk to it:

```bash
ssh-keyscan -H <address> >> ~/.ssh/known_hosts
```

Compare the fingerprint against your provider's console. Accepting whatever key
appears first is what host key checking exists to prevent.

Then check the connection — this configures nothing:

```bash
uv run ansible vpn -m ping
```

Every node should answer `pong`.

## 3. Fill in the inventory

**Addresses and domains.** The real `host_vars` files are gitignored, so start
from the committed examples:

```bash
for h in inventory/host_vars/*/; do cp "$h/main.yml.example" "$h/main.yml"; done
$EDITOR inventory/host_vars/*/main.yml
```

Each needs the node's address and the names it answers to:

```yaml
ansible_host: 198.51.100.7
vpn_domains:
  - v0.example.com      # primary: chains and subscription links use this
  - example.com         # alias: the shared apex, if this node serves it
```

The first domain is the node's primary. The rest are aliases and go into the
same certificate. An apex shared across nodes is a DNS round robin — fine for
the site, useless for a chain, which has to reach the node it names.

**Chains and users** live in
[`inventory/group_vars/all/main.yml`](../inventory/group_vars/all/main.yml). The
chain list is already written; what you need to set is the roster and the
notification address:

```yaml
vpn_users:
  - { name: boss, tier: all, rot: 1 }     # single-hop test chains as well
  - { name: alice, tier: main, rot: 1 }   # two-hop chains only

acme_email: "you@example.com"             # Let's Encrypt expiry notices
```

`rot` is a rotation counter. Bumping one user's `rot` reissues their UUID and
their link; nobody else is affected.

**Membership** is in [`inventory/hosts.yml`](../inventory/hosts.yml). A node
listed under `unmanaged` is skipped by every play — that is how a node already
carrying live traffic stays untouched while its peers still read its domain out
of the inventory.

## 4. Create the vault

The vault is an encrypted YAML file that Ansible decrypts in memory for the
length of a run.

```bash
openssl rand -hex 32                       # this is your vault_seed

cp inventory/group_vars/all/vault.yml.example /tmp/vault.yml
$EDITOR /tmp/vault.yml                     # seed, and the DNS provider token
uv run ansible-vault encrypt --output inventory/group_vars/all/vault.yml /tmp/vault.yml
shred -u /tmp/vault.yml                    # rm -P on macOS
```

**Put the vault password in a password manager.** Losing it means generating a
new seed, which changes every path and every subscription link.

To stop typing it on every run, write it to `.vault_pass` (gitignored) and
uncomment `vault_password_file` in [`ansible.cfg`](../ansible.cfg). Then drop
`--ask-vault-pass` from the commands below.

The DNS token needs `Zone:DNS:Edit` on the zone — certbot proves domain
ownership with it over dns-01.

## 5. DNS

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # gitignored
$EDITOR terraform.tfvars                        # token, zone id, names, addresses
terraform init
terraform apply
cd ..
```

Records must resolve **before** the first run — certificates cannot be issued
until they do:

```bash
dig +short v0.example.com
```

## 6. First run, one node at a time

Start with a node that has a single-hop test chain. It proves the whole shape
works — angie, certificate, xray, egress — without depending on any other node
being ready.

```bash
uv run ansible-playbook site.yml --limit v3 --skip-tags verify --ask-vault-pass
```

`--limit` restricts the run to one node. `--skip-tags verify` leaves the checks
out: this node's two-hop chains point at nodes that do not exist yet, and the
check would correctly fail on them.

Expect a few minutes, most of it certbot waiting for the DNS record to
propagate. Then look at it yourself:

```bash
curl -I https://v3.example.com
curl -I https://example.com        # the apex, if this node serves it
```

Both should return 200 and the static site.

> **About `--check`.** Guides usually suggest a dry run first. On a *fresh*
> node it produces a wall of false failures: packages are not installed, so the
> tasks depending on them cannot even pretend. `--check` earns its place later,
> on a configured node, to see what an edit of yours would change.

## 7. Verify

```bash
uv run ansible-playbook site.yml --tags verify --limit v3 --ask-vault-pass
```

The [`verify` role](../roles/verify/README.md) does three things:

1. asserts xray holds **no** network socket — every inbound is a unix socket;
2. asserts only 22, 80 and 443 are reachable and nftables still drops by
   default;
3. starts a throwaway client and actually sends traffic through each chain,
   comparing the address it came out at against the chain's exit node.

The first two protect the property the whole design rests on: nothing reaches
xray without passing through angie. The third is the only one that tells you it
*works* rather than that it is configured.

With one node up, only its test chain passes, and it exits at itself. That is
correct.

## 8. The remaining nodes

```bash
uv run ansible-playbook site.yml --limit v2 --skip-tags verify --ask-vault-pass
uv run ansible-playbook site.yml --limit v0 --skip-tags verify --ask-vault-pass
uv run ansible-playbook site.yml --ask-vault-pass          # everything, with checks
```

The final run reports each chain: `v0-v2 came out at …, expected …`. This is
where assumptions about which nodes can reach which get settled by measurement.

### Taking over an unmanaged node

A node in the `unmanaged` group is skipped, and chains touching it are kept out
of subscriptions — nothing is listening at the far end, so publishing them would
hand users links that cannot work. When you can reconfigure it:

```bash
$EDITOR inventory/hosts.yml                                # remove it from `unmanaged`
uv run ansible-playbook site.yml --limit v1 --ask-vault-pass
uv run ansible-playbook site.yml --tags users --ask-vault-pass
```

The second command is what puts the newly usable chains into everyone's
subscription.

## 9. Hand out subscriptions

```bash
uv run ansible-playbook site.yml --tags subscription -v \
  -e subscription_show_links=true --ask-vault-pass
```

**The link is the credential.** Whoever holds it has access, which is why it is
not printed by default. Send it over something private, not a group chat.

Users paste it into their client as a *subscription*; configs then update
themselves. The same URL with `.html` appended is a readable page with the link,
a copy button and a short explanation — easier to send to someone non-technical.

Give people the link from whichever node stays reachable for them.

## 10. Routine operations

| Task | How |
|---|---|
| Add a user | a line under `vpn_users`, then `--tags users` |
| Revoke access | remove the line, `--tags users`, then delete their file from `/var/www/sub` |
| Reissue someone's link | `rot: 2` for them, then `--tags users` |
| Change a tier | `tier: main` ↔ `tier: all`, then `--tags users` |
| Add a chain | an entry under `vpn_chains`, then a full run |
| Add a node | `hosts.yml`, its `host_vars` pair, its chains, a DNS record |
| Change the site | edit [`roles/website/files/site/`](../roles/website/files/site/), then `--tags website` |
| Check nothing changed underneath you | `--tags verify` |
| Rotate everything | change `vault_seed` — every path and link changes with it |

## 11. When something breaks

Run `--tags verify` first. It prints what every chain answered before it fails,
and that answer narrows things down immediately:

| Answer | Meaning | Where to look |
|---|---|---|
| `nothing` | the chain never replied | `journalctl -u xray` and `/var/log/angie/error.log` on the entry node |
| the entry node's own address | the second hop did not happen; traffic left where it arrived | the routing rule for that inbound, and whether the outbound can reach the far node |
| some third address | the node egresses from a different address than it accepts management traffic on | set `vpn_egress_ip` for that host and re-run |

Two causes account for most "it all suddenly stopped": **clock drift**, which
VLESS does not tolerate, and an **expired certificate**. `chrony` and certbot's
renewal timer handle both, so check that both are actually running:

```bash
uv run ansible vpn -m command -a 'chronyc tracking'
uv run ansible vpn -m command -a 'certbot certificates'
```

Useful flags while debugging:

* `-v` for more output, `-vvv` for everything including the SSH conversation.
* `--start-at-task "task name"` to resume from where a run stopped.
* `--limit <node>` to work on one node without touching the others.
* `--check --diff` on a configured node to see what an edit would change.

## 12. Before you change anything

```bash
pre-commit run --all-files
uv run ansible-playbook site.yml --syntax-check
```

To exercise the templates without any nodes, render them locally: a throwaway
playbook with `connection: local` that pulls each role's `defaults/main.yml` in
through `vars_files` and runs `ansible.builtin.template` against the files in
`roles/*/templates/`. Rendering all of them for every node takes a few seconds
and catches most mistakes before a node ever sees them.

After changing topology, angie or xray, finish with `--tags verify`. Everything
else can pass on a deployment that does not carry a single byte.
