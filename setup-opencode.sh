#!/bin/bash
set -e

# ============================================================
# Concentrate AI - opencode Setup
# Supports: curl|bash, direct execution, piped/agent input
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/AjayK47/concentrate-opencode/main/setup-opencode.sh | bash
#   bash setup-opencode.sh
#   bash setup-opencode.sh --key <API_KEY>
#   bash setup-opencode.sh --key <API_KEY> --model claude-sonnet-5-5
#   echo "<API_KEY>" | bash setup-opencode.sh
# ============================================================

VERSION="1.0.0"
SCRIPT_URL="https://raw.githubusercontent.com/AjayK47/concentrate-opencode/main/setup-opencode.sh"
API_BASE="https://api.concentrate.ai"
DOCS_URL="https://github.com/AjayK47/concentrate-opencode"
PROVIDER_ID="concentrate"
DEFAULT_MODEL="claude-sonnet-5-5"
DEFAULT_SMALL_MODEL="claude-haiku-4-5"

# Colors (disabled if not outputting to a terminal)
if [ -t 1 ] || (echo '' > /dev/tty) 2>/dev/null; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  BOLD='\033[1m'
  DIM='\033[2m'
  NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' BOLD='' DIM='' NC=''
fi

# --- Helpers ---
info()  { echo -e "${BLUE}ℹ${NC}  $*"; }
ok()    { echo -e "${GREEN}✅${NC} $*"; }
warn()  { echo -e "${YELLOW}⚠️${NC}  $*"; }
fail()  { echo -e "${RED}❌${NC} $*"; exit 1; }

# --- Parse arguments ---
api_key=""
default_model=""
set_default=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --key|-k)        api_key="$2"; shift 2 ;;
    --model|-m)      default_model="$2"; set_default=true; shift 2 ;;
    --no-default)    set_default=false; shift ;;
    --help|-h)
      echo "Usage: setup-opencode.sh [--key <API_KEY>] [--model <MODEL_ID>] [--no-default]"
      echo ""
      echo "Options:"
      echo "  --key, -k      Provide API key non-interactively"
      echo "  --model, -m    Set concentrate/<MODEL_ID> as opencode's default model"
      echo "  --no-default   Add the provider without changing opencode's default model"
      echo "  --help, -h     Show this help message"
      exit 0
      ;;
    *) shift ;;
  esac
done

# --- Banner ---
echo ""
echo -e "${BOLD}============================================================${NC}"
echo -e "${BOLD}  Concentrate AI — opencode Setup  ${DIM}v${VERSION}${NC}"
echo -e "${BOLD}============================================================${NC}"
echo ""

# --- Prerequisite checks ---
command -v curl >/dev/null 2>&1 || fail "curl is required but not installed."

# python3 edits opencode's JSON/JSONC config. On macOS, /usr/bin/python3 can be a
# stub that only offers to install the Command Line Tools, so actually run it.
if ! python3 -c 'import json' >/dev/null 2>&1; then
  echo ""
  echo "  python3 is required to update your opencode config."
  if [[ "$OSTYPE" == "darwin"* ]]; then
    echo -e "    ${YELLOW}xcode-select --install${NC}"
  else
    echo -e "    ${YELLOW}sudo apt install python3${NC}   (or your distro's equivalent)"
  fi
  echo ""
  fail "python3 must be installed before running setup."
fi

has_opencode=true
if ! command -v opencode >/dev/null 2>&1; then
  has_opencode=false
  warn "opencode CLI not found — configuring anyway."
  echo -e "     ${DIM}Install it with: curl -fsSL https://opencode.ai/install | bash${NC}"
else
  ok "opencode CLI detected"
fi

config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
data_dir="${XDG_DATA_HOME:-$HOME/.local/share}/opencode"
auth_file="$data_dir/auth.json"

# opencode merges opencode.json then opencode.jsonc from the global config dir;
# edit whichever the user already has, preferring .jsonc since it wins the merge.
if [ -f "$config_dir/opencode.jsonc" ]; then
  config_file="$config_dir/opencode.jsonc"
else
  config_file="$config_dir/opencode.json"
fi

# --- Read API key (interactive or piped) ---
read_input() {
  local prompt="$1"
  local secret="${2:-true}"

  # Try /dev/tty first (needed for curl|bash where stdin is the script)
  if (echo '' > /dev/tty) 2>/dev/null; then
    if [ "$secret" = "true" ]; then
      local val="" char
      printf "%s" "$prompt"
      while IFS= read -r -s -n 1 char < /dev/tty; do
        if [[ -z "$char" || "$char" == $'\n' || "$char" == $'\r' ]]; then break; fi
        if [[ "$char" == $'\x7f' || "$char" == $'\b' ]]; then
          if [[ -n "$val" ]]; then val="${val%?}"; printf "\b \b"; fi
          continue
        fi
        val+="$char"; printf "*"
      done
      printf "\n"
      REPLY="$val"
    else
      printf "%s" "$prompt"
      read -r REPLY < /dev/tty
    fi
  else
    # Fallback: stdin (direct run or piped/agent input)
    printf "%s" "$prompt"
    if [ "$secret" = "true" ]; then
      read -r -s REPLY || true
    else
      read -r REPLY || true
    fi
    printf "\n"
  fi
}

confirm() {
  local prompt="$1"
  local default="${2:-y}"
  if [ "$default" = "y" ]; then
    prompt="$prompt [Y/n] "
  else
    prompt="$prompt [y/N] "
  fi
  read_input "$prompt" false
  local answer="${REPLY:-$default}"
  [[ "$answer" =~ ^[Yy] ]]
}

mask() { echo "${1:0:8}...${1: -4}"; }

if [ -z "$api_key" ] && [ -n "$CONCENTRATE_API_KEY" ]; then
  info "Found existing CONCENTRATE_API_KEY in environment: ${BOLD}$(mask "$CONCENTRATE_API_KEY")${NC}"
  if confirm "  Use existing key?"; then
    api_key="$CONCENTRATE_API_KEY"
  fi
fi

if [ -z "$api_key" ] && [ -f "$auth_file" ]; then
  stored_key=$(python3 - "$auth_file" "$PROVIDER_ID" << 'PYEOF' 2>/dev/null || true
import json, sys
print(json.load(open(sys.argv[1])).get(sys.argv[2], {}).get("key", ""))
PYEOF
)
  if [ -n "$stored_key" ]; then
    info "Found existing Concentrate key in opencode: ${BOLD}$(mask "$stored_key")${NC}"
    if confirm "  Use existing key?"; then
      api_key="$stored_key"
    fi
  fi
fi

if [ -z "$api_key" ]; then
  echo ""
  echo "  Get your API key at: https://concentrate.ai/api-keys"
  echo ""
  read_input "  Enter your Concentrate API key: " true
  api_key="$REPLY"
fi

[ -z "$api_key" ] && fail "API key cannot be empty."

# --- Verify API key ---
echo ""
info "Verifying API key..."

http_code=$(
  curl -s -o /dev/null -w "%{http_code}" -X POST "${API_BASE}/v1/responses" \
    -H "Authorization: Bearer $api_key" \
    -H "Content-Type: application/json" \
    -d '{"model":"bluelobster/gpt-oss-20b","input":[{"role":"user","content":"test"}],"max_output_tokens":1}' 2>/dev/null
) || fail "Could not reach ${API_BASE}. Check your internet connection."

if [[ "$http_code" = "401" || "$http_code" = "403" ]]; then
  fail "Invalid API key. Check your key at https://concentrate.ai/settings/api-keys"
fi
if [[ "$http_code" = "402" ]]; then
  fail "Your API key is valid but has no credits left. Top up at https://concentrate.ai"
fi
if [[ "$http_code" =~ ^[45] ]]; then
  fail "API verification failed (HTTP $http_code)."
fi

ok "API key verified"

# --- Fetch model catalog ---
info "Fetching model catalog..."

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT
catalog_file="$tmp_dir/models.json"

curl -fsS "${API_BASE}/v1/models/" -H "Authorization: Bearer $api_key" -o "$catalog_file" 2>/dev/null \
  || fail "Could not fetch the model catalog from ${API_BASE}/v1/models/."

model_count=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["data"]))' "$catalog_file" 2>/dev/null) \
  || fail "Unexpected response from ${API_BASE}/v1/models/."
ok "Found ${BOLD}${model_count}${NC} models"

# --- Choose default model ---
if [ -z "$set_default" ]; then
  echo ""
  if confirm "  Make Concentrate opencode's default provider?"; then
    set_default=true
    read_input "  Default model [${DEFAULT_MODEL}]: " false
    default_model="${REPLY:-$DEFAULT_MODEL}"
  else
    set_default=false
  fi
fi

# --- Configure opencode ---
echo ""
info "Configuring opencode..."

mkdir -p "$config_dir" "$data_dir"
stamp=$(date +%Y%m%d_%H%M%S)
[ -f "$config_file" ] && cp "$config_file" "${config_file}.backup.${stamp}"
[ -f "$auth_file" ] && cp "$auth_file" "${auth_file}.backup.${stamp}"

if ! python3 - "$catalog_file" "$config_file" "$auth_file" "$PROVIDER_ID" "$api_key" \
  "$set_default" "$default_model" "$DEFAULT_SMALL_MODEL" > "$tmp_dir/notes" << 'PYEOF'
import json, os, re, sys

catalog_file, config_file, auth_file, provider_id, api_key, set_default, default_model, small_model = sys.argv[1:]

def strip_jsonc(text):
    """Remove // and /* */ comments and trailing commas, leaving strings intact."""
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

def load(path):
    if not os.path.exists(path):
        return {}, False
    raw = open(path).read()
    if not raw.strip():
        return {}, False
    cleaned = strip_jsonc(raw)
    return json.loads(cleaned), cleaned.strip() != raw.strip()

def usd(price):
    return (price or {}).get("price", {}).get("USD")

def to_opencode(m):
    routes = list((m.get("providers") or {}).values())
    supports = [r.get("supports") or {} for r in routes]
    caps = m.get("capabilities") or {}
    has = lambda key: bool((caps.get(key) or {}).get("supported"))

    tool_call = any((s.get("tools") or {}).get("function_calling") for s in supports)
    temperature = any(s.get("temperature") for s in supports)
    reasoning = has("thinking") or has("effort") or any(s.get("reasoning") for s in supports)
    inputs = ["text"] + (["image"] if has("image_input") else []) + (["pdf"] if has("pdf_input") else [])

    entry = {
        "name": m.get("display_name") or m.get("name") or m["id"],
        "attachment": len(inputs) > 1,
        "reasoning": reasoning,
        "tool_call": tool_call,
        "temperature": temperature,
        "modalities": {"input": inputs, "output": ["text"]},
    }
    if (m.get("created_at") or "")[:10]:
        entry["release_date"] = m["created_at"][:10]

    context = m.get("max_input_tokens") or max((r.get("context_window") or 0 for r in routes), default=0)
    output = m.get("max_tokens") or max((r.get("max_output_tokens") or 0 for r in routes), default=0)
    limit = {k: v for k, v in (("context", context), ("output", output)) if v}
    if limit:
        entry["limit"] = limit

    # Price shown in opencode is per 1M tokens; use the first (primary) route.
    tokens = next((r["pricing"][0].get("tokens") or {} for r in routes if r.get("pricing")), {})
    cost = {"input": usd(tokens.get("input")), "output": usd(tokens.get("output"))}
    cache = tokens.get("cache") or {}
    cost["cache_read"] = usd(cache.get("read"))
    cost["cache_write"] = usd((cache.get("write") or {}).get("ephemeral_5m_input_tokens"))
    cost = {k: v for k, v in cost.items() if v is not None}
    if "input" in cost and "output" in cost:
        entry["cost"] = cost
    return entry

catalog = json.load(open(catalog_file))["data"]
models = {m["id"]: to_opencode(m) for m in catalog if m.get("id")}

config, had_comments = load(config_file)
config.setdefault("$schema", "https://opencode.ai/config.json")
config.setdefault("provider", {})[provider_id] = {
    "npm": "@ai-sdk/openai-compatible",
    "name": "Concentrate",
    "env": ["CONCENTRATE_API_KEY"],
    "options": {"baseURL": "https://api.concentrate.ai/v1"},
    "models": models,
}

notes = []
if set_default == "true":
    if default_model not in models:
        notes.append(f"WARN Model '{default_model}' is not in the catalog — default model left unchanged.")
    else:
        config["model"] = f"{provider_id}/{default_model}"
        if small_model in models:
            config["small_model"] = f"{provider_id}/{small_model}"
        notes.append(f"OK Default model set to {provider_id}/{default_model}")
if had_comments:
    notes.append("WARN Comments in your config were removed (a backup was saved alongside it).")

with open(config_file, "w") as f:
    json.dump(config, f, indent=2)
    f.write("\n")

# Store the key the same way `opencode auth login` does.
auth, _ = load(auth_file)
auth[provider_id] = {"type": "api", "key": api_key}
fd = os.open(auth_file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump(auth, f, indent=2)
os.chmod(auth_file, 0o600)

print("\n".join(notes))
PYEOF
then
  fail "Could not update opencode config. Your backups are next to the original files."
fi

ok "Provider added ($config_file)"
ok "API key stored ($auth_file)"
while IFS= read -r line; do
  case "$line" in
    OK\ *)   ok "${line#OK }" ;;
    WARN\ *) warn "${line#WARN }" ;;
  esac
done < "$tmp_dir/notes"

# A stale provider block in the other global config file would be deep-merged in.
for other in "$config_dir/opencode.json" "$config_dir/config.json"; do
  if [ "$other" != "$config_file" ] && [ -f "$other" ] && grep -q "\"$PROVIDER_ID\"" "$other" 2>/dev/null; then
    warn "$other also mentions \"$PROVIDER_ID\" and is merged with $config_file — remove it there to avoid stale models."
  fi
done

# --- Health check ---
echo ""
info "Running health check..."

if [ "$has_opencode" = true ]; then
  listed=$(opencode models "$PROVIDER_ID" 2>/dev/null | grep -c "^$PROVIDER_ID/" || true)
  if [ "${listed:-0}" -gt 0 ]; then
    ok "opencode sees ${BOLD}${listed}${NC} Concentrate models"
  else
    warn "opencode did not list any Concentrate models — run: opencode models $PROVIDER_ID"
  fi
else
  health_code=$(
    curl -s -o /dev/null -w "%{http_code}" "${API_BASE}/v1/models" \
      -H "Authorization: Bearer $api_key" 2>/dev/null
  ) || true
  if [[ "$health_code" == "200" ]]; then
    ok "API connection healthy"
  else
    warn "Health check returned HTTP $health_code (non-critical)"
  fi
fi

# --- Offer to save script locally ---
echo ""
if confirm "  Save this setup script to ~/setup-opencode.sh to refresh models later?" n; then
  if [ -f "$0" ] && [ "$0" != "bash" ] && [ "$0" != "-bash" ]; then
    cp "$0" "$HOME/setup-opencode.sh" 2>/dev/null || curl -fsSL "$SCRIPT_URL" -o "$HOME/setup-opencode.sh" 2>/dev/null || true
  else
    curl -fsSL "$SCRIPT_URL" -o "$HOME/setup-opencode.sh" 2>/dev/null || true
  fi
  if [ -f "$HOME/setup-opencode.sh" ]; then
    chmod +x "$HOME/setup-opencode.sh"
    ok "Saved to ~/setup-opencode.sh"
    echo -e "     ${DIM}Re-run anytime to pick up new models: ~/setup-opencode.sh${NC}"
  else
    warn "Could not save script (non-critical)"
  fi
fi

# --- Summary ---
echo ""
echo -e "${BOLD}============================================================${NC}"
echo -e "${GREEN}${BOLD}  Setup Complete!${NC}"
echo -e "${BOLD}============================================================${NC}"
echo ""
echo "  What was configured:"
echo ""
echo -e "    ${GREEN}✓${NC} $config_file  ${DIM}(provider \"$PROVIDER_ID\", $model_count models)${NC}"
echo -e "    ${GREEN}✓${NC} $auth_file  ${DIM}(API key)${NC}"
echo ""
echo -e "  ${BOLD}Next steps:${NC}"
echo ""
echo -e "  1. Launch opencode:"
echo -e "       ${YELLOW}opencode${NC}"
echo ""
echo -e "  2. Pick a Concentrate model with ${YELLOW}/models${NC}, or start with one directly:"
echo -e "       ${YELLOW}opencode -m $PROVIDER_ID/${default_model:-$DEFAULT_MODEL}${NC}"
echo ""
echo -e "  ${DIM}Docs: ${DOCS_URL}${NC}"
echo -e "  ${DIM}Models: opencode models $PROVIDER_ID${NC}"
echo ""
