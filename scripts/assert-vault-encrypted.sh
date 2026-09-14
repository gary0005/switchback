#!/bin/sh
# Refuses to let an unencrypted vault reach a commit.
#
# The vault is the one committed file holding values that must not be read:
# vault_seed, from which every path, UUID and subscription token is derived,
# and the address Let's Encrypt notifies. `ansible-vault encrypt` is a separate
# step from editing, so forgetting it is easy — and the resulting file looks
# entirely ordinary in a diff.
#
# The secret scanners alongside this hook do not help: they are configured to
# skip vault files precisely because an encrypted payload is high-entropy by
# definition, and would otherwise be flagged on every commit.
set -eu

status=0

for file in "$@"; do
    [ -f "$file" ] || continue
    if [ "$(head -c 14 "$file")" != '$ANSIBLE_VAULT' ]; then
        echo "$file is not encrypted." >&2
        echo "  Encrypt it in place:  ansible-vault encrypt $file" >&2
        status=1
    fi
done

exit "$status"
