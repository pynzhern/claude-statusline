#!/bin/sh
# claude-statusline installer
# installs a rich statusline for Claude Code showing:
#   cwd · git branch · model · context bar · 5h/7d plan usage · prepaid balance
#
# supported: macOS, Linux
# requires:  python3, pip, jq, bc

set -e

CLAUDE_DIR="$HOME/.claude"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── colour helpers ─────────────────────────────────────────────────────────────
GREEN=$(printf '\033[32m'); AMBER=$(printf '\033[38;5;214m')
RED=$(printf '\033[31m');   RESET=$(printf '\033[0m')
ok()   { printf '%s✓%s  %s\n' "$GREEN" "$RESET" "$1"; }
warn() { printf '%s!%s  %s\n' "$AMBER" "$RESET" "$1"; }
fail() { printf '%s✗%s  %s\n' "$RED"   "$RESET" "$1"; exit 1; }

echo ""
echo "  claude-statusline installer"
echo "  ─────────────────────────────"
echo ""

# ── dependency checks ──────────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1 || fail "python3 not found — install it first"
command -v jq      >/dev/null 2>&1 || fail "jq not found — brew install jq / apt install jq"
command -v bc      >/dev/null 2>&1 || fail "bc not found — install it via your package manager"
ok "dependencies: python3, jq, bc"

# ── pycryptodome ───────────────────────────────────────────────────────────────
if python3 -c "from Crypto.Cipher import AES" 2>/dev/null; then
  ok "pycryptodome already installed"
else
  warn "installing pycryptodome..."
  pip3 install pycryptodome --quiet || fail "pip3 install pycryptodome failed"
  ok "pycryptodome installed"
fi

# ── platform check ─────────────────────────────────────────────────────────────
platform=$(uname -s)
case "$platform" in
  Darwin) ok "platform: macOS" ;;
  Linux)  ok "platform: Linux" ;;
  *)      fail "unsupported platform: $platform (Windows not yet supported)" ;;
esac

# ── copy scripts ───────────────────────────────────────────────────────────────
mkdir -p "$CLAUDE_DIR"
cp "$SCRIPT_DIR/statusline-command.sh" "$CLAUDE_DIR/statusline-command.sh"
cp "$SCRIPT_DIR/statusline-usage.py"   "$CLAUDE_DIR/statusline-usage.py"
chmod +x "$CLAUDE_DIR/statusline-command.sh"
ok "scripts copied to $CLAUDE_DIR"

# ── patch settings.json ────────────────────────────────────────────────────────
SETTINGS="$CLAUDE_DIR/settings.json"

# create settings file if it doesn't exist
if [ ! -f "$SETTINGS" ]; then
  printf '{}' > "$SETTINGS"
fi

# use python to safely merge settings (handles existing keys)
python3 << PYEOF
import json, sys

path = '$SETTINGS'
with open(path) as f:
    s = json.load(f)

s['statusLine'] = {
    'type': 'command',
    'command': 'bash $CLAUDE_DIR/statusline-command.sh',
    'refreshInterval': 60
}

# add Stop hook to clear cache after each response
hooks = s.get('hooks', {})
stop  = hooks.get('Stop', [])

# avoid duplicating the hook
cache_cmd = 'rm -f /tmp/claude_usage_cache.json'
already   = any(
    any(h.get('command') == cache_cmd for h in entry.get('hooks', []))
    for entry in stop
)
if not already:
    stop.append({'hooks': [{'type': 'command', 'command': cache_cmd}]})

hooks['Stop'] = stop
s['hooks']    = hooks

with open(path, 'w') as f:
    json.dump(s, f, indent=2)

print('settings.json updated')
PYEOF

ok "settings.json patched (statusLine + Stop hook)"

# ── smoke test ─────────────────────────────────────────────────────────────────
echo ""
echo "  running a quick smoke test..."
echo ""
result=$(echo '{"cwd":"'"$HOME"'","model":{"display_name":"claude-sonnet-4-6"},"context_window":{"used_percentage":35}}' \
  | bash "$CLAUDE_DIR/statusline-command.sh" 2>/dev/null || true)

if [ -n "$result" ]; then
  printf '  preview: %s\n' "$result"
  echo ""
  ok "smoke test passed"
else
  warn "statusline returned empty output — usage data may not be available until the Claude desktop app has been opened and you are signed in"
fi

echo ""
echo "  ─────────────────────────────"
echo "  done! restart Claude Code (or run /hooks) to activate the statusline."
echo ""
