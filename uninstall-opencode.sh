#!/bin/bash
set -uo pipefail

# Concentrate AI - opencode Uninstall
# Removes the provider, default model and stored key added by setup-opencode.sh.
# CONCENTRATE_API_KEY in your shell profile is left alone, since other
# Concentrate integrations (Claude Code, Codex, ...) share it.
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/AjayK47/concentrate-opencode/main/uninstall-opencode.sh | bash

PROVIDER_ID="concentrate"

# Colors (off when piped)
if [ -t 1 ]; then
  G='\033[0;32m' Y='\033[1;33m' R='\033[0;31m' B='\033[1m' N='\033[0m'
else
  G='' Y='' R='' B='' N=''
fi

info() { echo -e "${Y}>${N} $*"; }
ok()   { echo -e "${G}+${N} $*"; }

echo ""
echo -e "${B}Concentrate AI — opencode Uninstall${N}"
echo ""

if ! python3 -c 'import json' >/dev/null 2>&1; then
  echo -e "${R}x${N} python3 is required to edit your opencode config."
  exit 1
fi

config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
auth_file="${XDG_DATA_HOME:-$HOME/.local/share}/opencode/auth.json"
stamp=$(date +%Y%m%d_%H%M%S)

# --- Remove provider and default model from every global config file ---
info "Cleaning opencode config..."
cleaned=0
for config_file in "$config_dir/opencode.jsonc" "$config_dir/opencode.json" "$config_dir/config.json"; do
  [ -f "$config_file" ] || continue
  grep -q "$PROVIDER_ID" "$config_file" 2>/dev/null || continue
  cp "$config_file" "${config_file}.backup.${stamp}"
  if python3 - "$config_file" "$PROVIDER_ID" << 'PYEOF'
import json, re, sys

path, provider_id = sys.argv[1:]

def strip_jsonc(text):
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            out.append(text[i:j + 1])
            i = j + 1
        elif text.startswith("//", i):
            while i < n and text[i] != "\n":
                i += 1
        elif text.startswith("/*", i):
            end = text.find("*/", i + 2)
            i = n if end == -1 else end + 2
        else:
            out.append(c)
            i += 1
    return re.sub(r",(\s*[}\]])", r"\1", "".join(out))

config = json.loads(strip_jsonc(open(path).read()) or "{}")
changed = config.get("provider", {}).pop(provider_id, None) is not None
if config.get("provider") == {}:
    del config["provider"]
for key in ("model", "small_model"):
    if str(config.get(key, "")).startswith(provider_id + "/"):
        del config[key]
        changed = True
if changed:
    with open(path, "w") as f:
        json.dump(config, f, indent=2)
        f.write("\n")
PYEOF
  then
    ok "$config_file cleaned"
    cleaned=1
  else
    echo -e "${R}x${N} Could not parse $config_file — left unchanged"
  fi
done
[ "$cleaned" -eq 0 ] && ok "No opencode config needed cleaning"

# --- Remove stored API key ---
if [ -f "$auth_file" ] && grep -q "\"$PROVIDER_ID\"" "$auth_file" 2>/dev/null; then
  info "Removing stored API key..."
  cp "$auth_file" "${auth_file}.backup.${stamp}"
  python3 - "$auth_file" "$PROVIDER_ID" << 'PYEOF'
import json, os, sys
path, provider_id = sys.argv[1:]
auth = json.load(open(path))
auth.pop(provider_id, None)
with open(path, "w") as f:
    json.dump(auth, f, indent=2)
os.chmod(path, 0o600)
PYEOF
  ok "$auth_file cleaned"
fi

echo ""
echo -e "${G}${B}Uninstall complete!${N}"
echo ""
echo "  opencode will use its other configured providers next time it starts."
echo "  Pick a new default with:"
echo ""
echo -e "  ${Y}opencode${N}  then  ${Y}/models${N}"
echo ""
