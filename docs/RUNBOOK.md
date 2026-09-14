# Runbook

Deploying this from nothing, and running it afterwards. Assumes you are comfortable in a terminal and have not used Ansible before.

For what the deployment *is* and why it is shaped this way, read the [README](../README.md) first. This file is the sequence of commands.

## How Ansible works here

Ansible is ssh plus templates. Nothing is installed on the nodes to support it: you run `ansible-playbook` on your own machine, it connects to each node over SSH and carries out a list of steps — install a package, write a file, restart a service. Every step is written so it can run repeatedly; a second run changes nothing unless the repository changed.

Three words you will meet:

| Term | Here |
|---|---|
| inventory | the nodes and their variables — [`inventory/`](../inventory/) |
| role | the steps for one thing: install xray, configure angie — [`roles/`](../roles/) |
| playbook | what runs where — [`site.yml`](../site.yml) |

One property matters more than the rest: **everything derives from one secret.** Paths, user UUIDs and subscription tokens are not stored anywhere, they are recomputed from `vault_seed` on every run. There is no state to lose — and no way to change the seed without changing all of it at once.

## 1. Tooling

```bash
cd switchback
pip install pre-commit && pre-commit install
brew install certbot        # apt install certbot on Debian or Ubuntu
uv run ansible --version
```

**certbot belongs on this machine, not on the servers.** Certificates are issued here and only the files are shipped out, so that no node ever holds the DNS key — see [roles/acme/README.md](../roles/acme/README.md).

Every command below is `uv run ansible-…`. `.venv/bin/ansible-…` is the same thing if you prefer.

## 2. Fill in the inventory

**Addresses and domains.** The real `host_vars` files are gitignored, so start from the committed examples:

```bash
for h in inventory/host_vars/*/; do cp "$h/main.yml.example" "$h/main.yml"; done
```

Then edit all four `inventory/host_vars/*/main.yml` files. Each needs the node's address and the names it answers to:

```yaml
ansible_host: 198.51.100.7
vpn_domains:
  - v0.example.com      # primary: chains and subscription links use this
  - example.com         # alias: the apex, shared with the other nodes
```

The first domain is the node's primary — the name chains and subscription links address it by, so it must reach that node and no other. The rest are aliases and go into the same certificate. The apex can sit on several nodes at once, because dns-01 proves ownership by writing a TXT record rather than by being the node the name resolves to.

**Chains and users** live in [`inventory/group_vars/all/main.yml`](../inventory/group_vars/all/main.yml). The chain list is already written; what you need to set is the roster:

```yaml
vpn_users:
  - { name: ops, tier: all, rot: 1 }      # whoever debugs the deployment
  - { name: lead, tier: all, rot: 1 }     # single-hop test chains as well
  - { name: u-a, tier: main, rot: 1 }     # two-hop chains only
```

`rot` is a rotation counter. Bumping one user's `rot` reissues their UUID and their link; nobody else is affected.

**`name` is a label, not a person.** It derives the user's UUID and subscription token and tags them in xray's config — which means it is written in clear text onto every node, so real names do not belong here and the vault would not help. Keep who-is-who wherever you keep the vault password. And pick a label once: renaming it reissues that user's access, exactly as bumping `rot` does.

The address Let's Encrypt notifies, the DNS zone and its API credentials are not here — they go in the vault, in the next step but one. This file is committed, and neither a personal address nor a zone-wide API key belongs in it.

**Membership** is in [`inventory/hosts.yml`](../inventory/hosts.yml). A node listed under `unmanaged` is skipped by every play — that is how a node already carrying live traffic stays untouched while its peers still read its domain out of the inventory.

## 3. Reach the nodes

The roles connect as `root`, set in [`inventory/group_vars/all/ansible.yml`](../inventory/group_vars/all/ansible.yml). `ssh root@<node>` has to work with a key and no password. If your provider only gives you an unprivileged user, switch that file to `become` instead.

Host key checking is deliberately on, so each node has to be in `known_hosts` before Ansible will talk to it. **Scan exactly the value you put in `ansible_host`** — an address there means the entry has to be under that address. A `known_hosts` full of domain names does nothing for a connection made to an IP: with `-H` the name is hashed, and the hash of the domain is not the hash of the address. The error is `Host key verification failed`, reported as `UNREACHABLE`.

```bash
ssh-keyscan -T 10 -H 198.51.100.7 >> ~/.ssh/known_hosts
```

`-T 10` because the default five-second timeout is enough for a node under load to return nothing at all, silently, leaving you with an empty entry and the same error.

Compare the fingerprint against your provider's console. Accepting whatever key appears first is what host key checking exists to prevent.

The command also writes `# 198.51.100.7:22 SSH-2.0-OpenSSH_…` banner lines into the file. Those are comments, `known_hosts` ignores them, and they are harmless — leave them alone. Stripping the `#` is what turns them into lines ssh cannot parse.

Then check the connection — this configures nothing:

```bash
uv run ansible 'vpn:!unmanaged' -m ping
```

Every managed node should answer `pong`. The `!unmanaged` matters: a node held out of the deployment usually has no key of yours either, so plain `vpn` reports it as unreachable and that is correct rather than a problem to fix.

## 4. Create the vault

The vault is an encrypted YAML file that Ansible decrypts in memory for the length of a run.

```bash
openssl rand -hex 32                       # this is your vault_seed

cp inventory/group_vars/all/vault.yml.example /tmp/vault.yml
$EDITOR /tmp/vault.yml                     # seed, email, zone, API key and secret
uv run ansible-vault encrypt --output inventory/group_vars/all/vault.yml /tmp/vault.yml
shred -u /tmp/vault.yml                    # rm -P on macOS
```

**Put the vault password in a password manager.** Losing it means generating a new seed, which changes every path and every subscription link.

To stop typing it on every run, write it to `.vault_pass` (gitignored) and uncomment `vault_password_file` in [`ansible.cfg`](../ansible.cfg). Then drop `--ask-vault-pass` from the commands below.

Four values go in. `vault_seed`, which everything derives from. `vault_acme_email`, where expiry notices go — not a secret, but personal data with no business in a committed file. And `vault_dns_zone` with `vault_spaceship_api_key` and `vault_spaceship_api_secret`, which certbot uses to answer the dns-01 challenge.

**Create the API key in Spaceship's API Manager** with the `dnsrecords:write` scope. Two things to know about it: that scope covers **every domain in the account** — it cannot be narrowed to one domain or one record type — and the key is used **on this machine only**. Nodes never receive it, and `--tags verify` fails if one ever does. Because the scope cannot be narrowed, it is worth keeping this domain in an account of its own.

## 5. DNS

Records are maintained by hand, wherever your domain's nameservers point. There is no Terraform: the records change when you add a node or move a provider, which is rare enough that automating it costs more than it saves. `--tags verify` is what notices if they drift.

One A record per name in `vpn_domains`. Per-node names point at one node each; **the apex may point at several at once** — visitors round-robin between them, and every one of those nodes serves the same site. That works because dns-01 proves ownership by writing a TXT record rather than by being the node a name resolves to.

So for four nodes with three of them sharing the apex:

| Name | Points at |
|---|---|
| `v0.example.com` | v0 |
| `v1.example.com` | v1 |
| `v2.example.com` | v2 |
| `v3.example.com` | v3 |
| `example.com` | v0, v2 and v3 |

Records must resolve **before** the first run — certificates cannot be issued until the zone is right, and the challenge is written into that same zone:

```bash
for n in v0 v1 v2 v3; do echo "$n: $(dig +short A $n.example.com)"; done
dig +short A example.com
```

## 6. First run, one node at a time

Start with a node that has a single-hop test chain. It proves the whole shape works — angie, certificate, xray, egress — without depending on any other node being ready.

```bash
uv run ansible-playbook site.yml --limit v3 --skip-tags verify --ask-vault-pass
```

`--limit` restricts the run to one node. `--skip-tags verify` leaves the checks out: this node's two-hop chains point at nodes that do not exist yet, and the check would correctly fail on them.

Expect a few minutes, most of it certbot — running here, on your machine. For each name it writes a TXT record through the Spaceship API, waits until a public resolver can see it, then asks Let's Encrypt to check, and finally the certificate is copied to the node. A slow zone shows up as the run sitting quietly on the certificate task; if it gives up, raise `acme_dns_check_tries`. Then look at it yourself:

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
2. asserts only 22, 80 and 443 are reachable and nftables still drops by default;
3. starts a throwaway client and actually sends traffic through each chain, comparing the address it came out at against the chain's exit node.

The first two protect the property the whole design rests on: nothing reaches xray without passing through angie. The third is the only one that tells you it *works* rather than that it is configured.

With one node up, only its test chain passes, and it exits at itself. That is correct.

## 8. The remaining nodes

```bash
uv run ansible-playbook site.yml --limit v2 --skip-tags verify --ask-vault-pass
uv run ansible-playbook site.yml --limit v0 --skip-tags verify --ask-vault-pass
uv run ansible-playbook site.yml --ask-vault-pass          # everything, with checks
```

The final run reports each chain: `v0-v2 came out at …, expected …`. This is where assumptions about which nodes can reach which get settled by measurement.

### Taking over an unmanaged node

A node in the `unmanaged` group is skipped, and chains touching it are kept out of subscriptions — nothing is listening at the far end, so publishing them would hand users links that cannot work. The chains themselves are declared all along; only the far end is missing.

**Taking one over is destructive to whatever it was doing.** The first run overwrites `/etc/angie/`, replaces `/usr/local/etc/xray/config.json`, and applies an nftables ruleset that flushes what was there and leaves only 22, 80 and 443 open. Anything the node was serving on another port, or under another configuration, stops at that moment, and its existing users need new subscriptions issued from here. Plan the changeover before you start it.

When you are ready:

```bash
$EDITOR inventory/hosts.yml                  # remove it from `unmanaged`
$EDITOR inventory/group_vars/all/main.yml    # add its test chain, e.g. v1-solo
uv run ansible-playbook site.yml --limit v1 --skip-tags verify --ask-vault-pass
uv run ansible-playbook site.yml --tags users --ask-vault-pass
uv run ansible-playbook site.yml --tags verify --ask-vault-pass
```

The `users` run is what puts the newly usable chains into everyone's subscription; the `verify` run is what confirms they carry traffic. If the node should also serve the shared apex, add it to that node's `vpn_domains` and add the matching DNS record before the first command.

## 9. Hand out subscriptions

```bash
uv run ansible-playbook site.yml --tags subscription -v \
  -e subscription_show_links=true --ask-vault-pass
```

**The link is the credential.** Whoever holds it has access, which is why it is not printed by default. Send it over something private, not a group chat.

Users paste it into their client as a *subscription*; configs then update themselves. The same URL with `.html` appended is a readable page with the link, a copy button and a short explanation — easier to send to someone non-technical.

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
| Renew certificates | `--tags certs`, monthly — **nothing renews on its own** |
| Check nothing changed underneath you | `--tags verify` |
| Rotate everything | change `vault_seed` — every path and link changes with it |

## 11. When something breaks

### `UNREACHABLE` on every node

Ansible never got as far as the node, so nothing in the roles is involved. Add `-vvv` and read the line above the failure — it names the cause:

| Cause | Fix |
|---|---|
| `Host key verification failed` | the address in `ansible_host` is not in `known_hosts`; scan that exact value, not the domain that resolves to it |
| `Permission denied (publickey)` | your key is not in that node's `root` authorized_keys, or the provider only allows an unprivileged user |
| `Connection timed out` | wrong address, or the provider's own firewall is in front of port 22 |

`ansible_host` deliberately holds an address rather than a name: it keeps deployment independent of DNS, and `vpn_egress_ip` defaults to it, which the chain checks compare against. Putting a domain there would break that comparison.

### A chain does not come out where it should

Run `--tags verify` first. It prints what every chain answered before it fails, and that answer narrows things down immediately:

| Answer | Meaning | Where to look |
|---|---|---|
| `nothing` | the chain never replied | `journalctl -u xray` and `/var/log/angie/error.log` on the entry node |
| the entry node's own address | the second hop did not happen; traffic left where it arrived | the routing rule for that inbound, and whether the outbound can reach the far node |
| some third address | the node egresses from a different address than it accepts management traffic on | set `vpn_egress_ip` for that host and re-run |

Two causes account for most "it all suddenly stopped": **clock drift**, which VLESS does not tolerate, and an **expired certificate**. `chrony` and certbot's renewal timer handle both, so check that both are actually running:

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

To exercise the templates without any nodes, render them locally: a throwaway playbook with `connection: local` that pulls each role's `defaults/main.yml` in through `vars_files` and runs `ansible.builtin.template` against the files in `roles/*/templates/`. Rendering all of them for every node takes a few seconds and catches most mistakes before a node ever sees them.

After changing topology, angie or xray, finish with `--tags verify`. Everything else can pass on a deployment that does not carry a single byte.
