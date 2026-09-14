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
| every name resolves to this node, once | a record drifted from `vpn_domains`, or a name points at several nodes |

The first two are the ones worth having. A direct route to xray is what gets a deployment noticed and blocked, and it is exactly the kind of thing a well-meaning edit adds back without anyone noticing. Making it fail the run is cheaper than finding out from users.

The DNS check exists because nothing else holds the zone — there is no Terraform state, the records are maintained by hand at the registrar. It also catches the one mistake http-01 cannot survive: a name resolving to more than one node, which makes renewal succeed or fail by luck. Sixty days is a long time to not know that.

## The live check

Everything above can pass on a deployment that does not carry a single byte. So for each chain the node fronts, the role starts a throwaway xray client — SOCKS on loopback in front of the same VLESS+XHTTP/TLS/443 outbound a subscription hands out — asks an echo service where the request came from, and compares that against the chain's exit node.

For a two-hop chain the request climbs the whole route: this node's angie, this node's xray, the far node's angie, the far node's xray, and out. Nothing short of that proves the second hop exists.

The probe presents `vpn_probe_uuid`, which the xray role adds to every user-facing inbound. It rides the same inbound a user does, so a check cannot pass on a path users do not take.

Skipped under `--check`, which cannot run a client. Turn it off with `verify_live=false` to run the structural checks alone.

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
| `verify_domains` | `{{ vpn_domains }}` | Names that must resolve to this node, and to one address |
| `verify_node_address` | `{{ ansible_host }}` | The address they must resolve to |
| `verify_chains` | `{{ vpn_chains_ready }}` | Chains to check |
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
