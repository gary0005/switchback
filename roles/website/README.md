# website

The static site every domain serves at `/`, on every node.

**Outcome:** the contents of `website_source` copied to `website_root`, owned by root and world-readable.
**Idempotent:** yes — content is compared by checksum, so unchanged files are not rewritten.
**Atomic:** no; files are copied one at a time.
**Rollback:** none built in. The source is in git, so restoring means reverting the commit and re-running.

## This is the cover story

A domain that serves nothing at `/`, or serves an obvious placeholder, fails the first active probe against it. The site is therefore load-bearing, and two properties matter more than its content:

**It is identical on every node.** Nodes that serve different things are nodes that can be told apart, and told apart from each other is halfway to identified.

**It is plausible.** Something with a few pages that link to each other, a stylesheet, and a `robots.txt` reads as a site. A single page saying "nothing to see here" reads as a front.

The bundled pages are a plain notes site — no organisation, no branding, nothing that claims to be anyone. Replace them with whatever fits, keeping those two properties.

## Serving your own site

Point `website_source` at an absolute path to serve something built elsewhere:

```yaml
- name: Publish the static site
  ansible.builtin.import_role:
    name: website
  vars:
    website_source: /home/me/blog/public/
```

A bare relative name resolves inside this role's `files/`, which is where the default lives.

## Variables

Full specification with types and defaults: [`meta/argument_specs.yml`](meta/argument_specs.yml).

| Variable | Default | Purpose |
|---|---|---|
| `website_source` | `site/` | Directory whose contents are copied |
| `website_root` | `/var/www/site` | Document root; must match `angie_site_root` |

## Known gap

Files removed from the source are not removed from the node — `copy` adds and updates, it does not prune. Delete them by hand, or switch the deploy task to `ansible.posix.synchronize` with `delete: true` if that becomes a habit.
