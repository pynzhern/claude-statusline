# claude-statusline

A rich statusline for [Claude Code](https://claude.ai/code) that shows your working context, model, context window usage, and live Claude.ai plan limits — all colour-coded.

```
portfolio  ·  main*  ·  claude-sonnet-4-6  ·  ctx 51% [▓▓▓▓▓░░░░░]  ·  5h 62% [▓▓▓▓▓▓░░░░] ↻3h13m  ·  7d 19% [▓▓░░░░░░░░] ↻4d21h  ·  SGD 15.59
```

| Section | What it shows |
|---|---|
| `portfolio` | Basename of current working directory |
| `main*` | Git branch (`*` = uncommitted changes) |
| `claude-sonnet-4-6` | Active model |
| `ctx 51% [▓▓▓▓▓░░░░░]` | Context window used |
| `5h 62% [▓▓▓▓▓▓░░░░] ↻3h13m` | 5-hour session plan limit + reset countdown |
| `7d 19% [▓▓░░░░░░░░] ↻4d21h` | 7-day weekly plan limit + reset countdown |
| `SGD 15.59` | Prepaid credit balance |

**Colours:** green → amber (≥50%) → red (≥80%). Usage data refreshes after every Claude response and every 60 seconds in the background.

## Requirements

- [Claude Code](https://claude.ai/code) CLI
- Claude desktop app (macOS or Linux) — signed in to claude.ai
- `python3`, `jq`
- `pycryptodome`, `curl_cffi` Python packages (installed automatically by the installer)

## Install

```sh
git clone https://github.com/pynzhern/claude-statusline
cd claude-statusline
chmod +x install.sh
./install.sh
```

Then restart Claude Code to load the new settings.

## How it works

Claude Code runs `statusline-command.sh` and passes a JSON blob on stdin with the current session state (`cwd`, `model`, `context_window`, etc.). The shell script:

1. Parses session state with `jq`
2. Builds the context window bar
3. Calls `statusline-usage.py` for live plan usage data (cached 5 min)
4. Assembles the output with ANSI colour codes

### Fetching plan usage

`statusline-usage.py` authenticates with claude.ai by decrypting your session cookie from the Claude desktop app's Electron SQLite cookie database:

- **macOS** — reads the AES encryption key from macOS Keychain (`Claude Safe Storage`), derives a 16-byte key via PBKDF2-SHA1 (1003 iterations), decrypts the `v10`-prefixed cookie
- **Linux** — tries `libsecret` first, falls back to Electron's hardcoded `"peanuts"` password (1 iteration)

It then calls two internal claude.ai API endpoints:
- `/api/organizations/{org_id}/usage` — session/weekly utilisation and reset times
- `/api/organizations/{org_id}/prepaid/credits` — prepaid credit balance

Results are cached to `/tmp/claude_usage_cache.json` for 5 minutes. A `Stop` hook in Claude Code clears the cache after every response so you always see fresh numbers.

## Platform support

| Platform | Status |
|---|---|
| macOS | ✅ Supported |
| Linux | ✅ Supported (requires Claude desktop app or manual session cookie) |
| Windows | ❌ Not yet (DPAPI cookie decryption differs) |

## Customisation

Colour thresholds and the separator are set in `statusline-command.sh`. The bar is fixed at 10 segments. The colour scheme:

| Variable | Colour | Used for |
|---|---|---|
| `CYAN` | Cyan | Working directory |
| `BLUE` | Soft blue | Git branch |
| `PURPLE` | Purple | Model name |
| `GREEN` | Green | Usage < 50% |
| `AMBER` | Amber | Usage 50–79% |
| `RED` | Red | Usage ≥ 80% |
| `WHITE` | White | Credit balance |
