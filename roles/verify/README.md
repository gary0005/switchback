# verify

Assert that the node is still shaped correctly, then dial every chain it fronts and check where the traffic comes out.

**Outcome:** a run that fails loudly if xray is reachable from the network, if an unexpected port is open, if a socket angie proxies to is missing, if a name does not resolve to this node, or if a chain does not exit through the node it names.
**Idempotent:** yes — it changes nothing. The throwaway configs it writes are removed before it finishes, pass or fail.
**Atomic:** n/a.
**Rollback:** n/a.

Runs as its own play in `site.yml`, after the configuring play. Within a play, handlers fire at the end — checking before that would test the configuration the node had when the run *started*, which is exactly the case where a passing check means nothing.

## The structural checks

These do not ask whether the deployment works. They ask whether it is still built the way it has to be.

| Check | Fails when |
|---|---|
| `ss -ltunp` has no xray | xray holds a listening TCP or UDP socket |
| reachable ports ⊆ `verify_expected_ports` | anything but 22, 80 and 443 answers on a non-loopback address |
| ruleset says `policy drop`, opens nothing extra | the firewall has grown a port, or stopped dropping by default |
| every expected socket exists | angie proxies to a path xray is not listening on — a location returning 502 |
| every name resolves to this node | a record drifted away from `vpn_domains` |
| no DNS credential on the node | something introduced a zone API key, which this design does without |

The first two are the ones worth having. A direct route to xray is what gets a deployment noticed and blocked, and it is exactly the kind of thing a well-meaning edit adds back without anyone noticing. Making it fail the run is cheaper than finding out from users.

The credential check guards a property worth keeping: there is no DNS API key in this deployment at all. Certificates come over http-01 with the challenge distributed to the nodes over ssh, so nothing anywhere can rewrite the zone. A future change reaching for dns-01 "because it is simpler" would put an account-wide key on every node, and would do it quietly; this fails the run instead.

The DNS check exists because nothing else holds the zone — there is no Terraform state, the records are maintained by hand at the registrar. A name resolving to several nodes is fine and expected: the apex does that, and with dns-01 it costs nothing. What the check catches is a name that stopped pointing at this node at all, which otherwise shows up as a browser certificate error or a chain that cannot be dialled.

## The live check

Everything above can pass on a deployment that does not carry a single byte. So for each chain the node fronts, the role starts a throwaway xray client — SOCKS on loopback in front of the same VLESS+XHTTP/TLS/443 outbound a subscription hands out — asks an echo service where the request came from, and compares that against the chain's exit node.

For a two-hop chain the request climbs the whole route: this node's angie, this node's xray, the far node's angie, the far node's xray, and out. Nothing short of that proves the second hop exists.

The probe presents `vpn_probe_uuid`, which the xray role adds to every user-facing inbound. It rides the same inbound a user does, so a check cannot pass on a path users do not take.

Skipped under `--check`, which cannot run a client. Turn it off with `verify_live=false` to run the structural checks alone.

## Chains that are known to be blocked

Sometimes a route simply does not exist — a network between two nodes drops the connection, and no amount of configuration fixes it. Mark such a chain `blocked: true` in `vpn_chains` and it stays configured and stays dialled, but stops failing the run; the report still shows what it did, which is how you notice the day it starts working again.

It also drops out of `vpn_chains_ready`, so users are not handed a link that cannot work.

## When a chain check fails

The report shows what each chain answered before the assertion fires, so read that first:

* **`nothing`** — the chain did not answer at all. Look at angie's error log on the `via` node, then `systemctl status xray` on both ends.
* **an address that belongs to the `via` node** — the second leg did not happen; traffic egressed at the entry instead. The routing rule for that inbound is wrong, or its outbound failed and fell through to `direct`.
* **an address that belongs to neither** — the node egresses from an address other than the one Ansible reaches it on, which is common with some providers. Set `vpn_egress_ip` for that host and re-run.

## Variables

Full specification with types and defaults: [`meta/argument_specs.yml`](meta/argument_specs.yml).

| Variable | Default | Purpose |
|---|---|---|
| `verify_live` | `true` | Whether to dial the chains at all |
| `verify_expected_ports` | `[22, 80, 443]` | The complete set of ports a node may expose |
| `verify_echo_url` | `https://api.ipify.org` | Service echoing the caller's address as plain text |
| `verify_no_credential_paths` | `[/etc/letsencrypt, /etc/ssl/switchback]` | Searched for a credential that must not be here |
| `verify_no_credential_patterns` | `[*.env, *dns*api*, *credentials*]` | What counts as one |
| `verify_domains` | `{{ vpn_domains }}` | Names that must resolve to this node, among others |
| `verify_node_address` | `{{ ansible_host }}` | The address that must be among their records |
| `verify_chains` | `{{ vpn_chains_checkable }}` | Chains to dial |
| `verify_blocked_chains` | `{{ vpn_chains_blocked }}` | Dialled and reported, but never a failure |
| `verify_chain_data` | `{{ vpn_chain_data }}` | Per-chain paths and exits |
| `verify_probe_uuid` | `{{ vpn_probe_uuid }}` | Identity the probe presents |
| `verify_probe_port` | `10808` | Loopback port the throwaway client uses |
| `verify_probe_dir` | `/var/cache/xray-probe` | Scratch space, removed when the checks finish |
| `verify_probe_startup` | `10` | Seconds to wait for the client to come up |
| `verify_probe_timeout` | `25` | Seconds allowed for the request itself |
| `verify_transit_alpn` | `[h2]` | Must agree with `xray_transit_alpn` |

## Example

```bash
# structural checks only, no traffic
ansible-playbook site.yml --tags verify -e verify_live=false --ask-vault-pass

# one node, full check
ansible-playbook site.yml --tags verify --limit v3 --ask-vault-pass
```

## Note on the echo service

`verify_echo_url` is a third party, reached through the chain under test. It sees a request from the exit node — not from you, and not from a user — but it is still an external dependency the check leans on. Point it at something you run if that matters.
