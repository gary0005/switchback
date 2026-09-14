# Managing users

Everything about a user is one line in [`inventory/group_vars/all/main.yml`](../inventory/group_vars/all/main.yml):

```yaml
vpn_users:
  - { name: ops, tier: all, rot: 1 }
  - { name: lead, tier: all, rot: 2 }
  - { name: u-a, tier: main, rot: 1 }
```

Nothing else records who has access. The UUID and the subscription token are recomputed from `vault_seed` and that line on every run, so there is no user database to keep in sync and none to lose.

## Add someone

Add the line, then refresh what depends on the roster:

```bash
uv run ansible-playbook site.yml --tags users
```

That rebuilds xray's client lists on every node and re-renders the subscription files. It takes under a minute and touches nothing else.

Then read out their link:

```bash
uv run ansible-playbook site.yml --tags subscription -v -e subscription_show_links=true
```

Links are not printed by default, because the token in the URL *is* the access — printing one writes a credential into your shell history and into any log that captures the run. Send it over something private.

The link points at the shared apex rather than at one node, so it keeps working whichever node answers. The same URL with `.html` appended is a readable page with a copy button and a short explanation, which is the one to send to someone who has never set up a VPN client. It carries every language in `subscription_page_langs` at once and follows the reader's browser, so there is nothing to pick before sending it.

## Tiers

`tier` decides which kinds of chain a user gets:

| tier | Gets | For |
|---|---|---|
| `main` | two-hop chains | everyone |
| `all` | two-hop and single-hop | whoever debugs the deployment |

Single-hop chains exist to tell "the hop is broken" apart from "the node is broken". They exit where they enter, so they are a diagnostic, not a route worth handing out.

The mapping lives in `vpn_tier_kinds` next to the roster, and it is enforced on the servers, not in the file you hand over: a `main` user's UUID is absent from the single-hop inbounds altogether. Editing a subscription file by hand gets you nothing.

## Reissue a link

Bump `rot` and run `--tags users`. The user's UUID and token both change; nobody else is affected.

Do this when a link goes somewhere it should not have: the wrong chat, or a screenshot nobody thought about.

## Remove someone

**Get their token before you delete the line.** It derives from the name and `rot`, so once the line is gone you cannot work out which file on the servers was theirs without putting it back.

```bash
# 1. while the line is still there
uv run ansible-playbook site.yml --tags subscription -v -e subscription_show_links=true

# 2. delete the line, then
uv run ansible-playbook site.yml --tags users
```

Step 2 removes their UUID from every inbound, which is what actually revokes access — their client stops connecting immediately.

What it does **not** do is delete their subscription file. The `subscription` role writes files; it never removes them. Their old file stays on disk under a URL they still know, and although it now contains configs whose UUID no longer works, it is worth clearing out.

To see what is stale on a node:

```bash
uv run ansible 'vpn:!unmanaged' -m shell -a 'ls -1 /var/www/sub'
```

Files are named by token, and each user has two: `<token>` and `<token>.html`. Anything not belonging to a current user can go. There will be more clutter than you expect — the role keeps a timestamped backup on every change, so a node that has seen a few roster edits accumulates files ending in `~`. Those are old payloads under old names, and they are served by angie exactly like live ones.

Delete by name once you know the token:

```bash
uv run ansible 'vpn:!unmanaged' -m file -a 'path=/var/www/sub/<token> state=absent'
uv run ansible 'vpn:!unmanaged' -m file -a 'path=/var/www/sub/<token>.html state=absent'
```

## Names are labels, not people

`name` tells users apart, derives their UUID and token, and tags them in xray's config. None of that needs anyone's actual name, and the label is written in clear text to `/usr/local/etc/xray/config.json` on every node — putting a real name in the vault would hide it from this repository and from nowhere else.

Keep labels functional (`ops`, `lead`, `u-a`) and keep the mapping to actual people wherever you keep the vault password.

Pick a label once. It feeds the derivation, so renaming one reissues that user's access exactly as bumping `rot` does — and leaves the old files behind, the same way removal does.

## When a new chain appears

Users do not get chains automatically. A chain reaches subscriptions only when both its ends are configured and it is not marked blocked, and their client only sees it after the file is re-rendered:

```bash
uv run ansible-playbook site.yml --tags users
```

Their client then has to refresh the subscription itself. Most clients do not do that on a schedule, so tell people to pull it manually after you have changed the topology, or they will keep using the set they downloaded.
