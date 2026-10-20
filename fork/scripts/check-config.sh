#!/usr/bin/env bash
# Verifies the local herdr config disables background network fetches, and warns about
# installed plugins or cached remote detection manifests.
set -euo pipefail

CONFIG_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/herdr
STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/herdr
CONFIG=$CONFIG_DIR/config.toml
status=0

key_is_false() {
    awk -v key="$1" '
        /^[[:space:]]*\[/ { section = $0; gsub(/[[:space:]]/, "", section) }
        {
            line = $0
            sub(/#.*/, "", line)
            gsub(/[[:space:]]/, "", line)
            if (section == "[update]" && line == key "=false") found = 1
        }
        END { exit found ? 0 : 1 }
    ' "$CONFIG"
}

if [ ! -f "$CONFIG" ]; then
    echo "FAIL: $CONFIG does not exist"
    status=1
else
    for key in version_check manifest_check; do
        if key_is_false "$key"; then
            echo "ok:   [update] $key = false"
        else
            echo "FAIL: [update] $key = false is missing in $CONFIG"
            status=1
        fi
    done
fi

if [ -d "$CONFIG_DIR/plugins" ] && [ -n "$(ls -A "$CONFIG_DIR/plugins" 2>/dev/null)" ]; then
    echo "WARN: plugins installed under $CONFIG_DIR/plugins (plan: none)"
fi
if [ -d "$STATE_DIR/agent-detection" ] && [ -n "$(ls -A "$STATE_DIR/agent-detection" 2>/dev/null)" ]; then
    echo "WARN: remote detection manifests cached under $STATE_DIR/agent-detection; delete them to use only the bundled manifests"
fi

if [ $status -ne 0 ]; then
    cat <<EOF

Add to $CONFIG:

[update]
version_check = false
manifest_check = false
EOF
fi
exit $status
