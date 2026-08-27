# claude-statusline

A rich statusline for [Claude Code](https://claude.ai/code): working context, model, effort, context window, and live Claude.ai plan limits — colour-coded, and wrapped to one or two lines depending on how wide your terminal is.

```
portfolio  ·  main*  ·  #42  ·  Fable 5  ·  high  ·  ctx 22%  ·  5h 55% [█████▌    ] ↻3h22m  ·  7d 41% [████      ] ↻4d15h  ·  fable 40%
```

| Segment | What it shows | Source |
|---|---|---|
| `portfolio` | Basename of the current working directory | stdin |
| `main*` | Git branch (`*` = uncommitted changes) | `git` |
| `#42` | Open PR/MR for the branch — green approved · amber pending · red changes requested · grey draft | stdin (Claude Code ≥ 2.1) |
| `Fable 5` | Model that actually produced the last response | transcript |
| `high` | Live `/effort` level, including the session-only `max` | stdin (Claude Code ≥ 2.1) |
| `ctx 22%` | Context window used; `ctx 22%/1M` when the window isn't the 200k default | stdin |
| `5h 55% […] ↻3h22m` | 5-hour session limit + reset countdown | stdin (native) or cookie helper |
| `7d 41% […] ↻4d15h` | 7-day weekly limit + reset countdown | stdin (native) or cookie helper |
| `fable 40%` | Model-scoped weekly cap (plans that cap one model separately) | cookie helper |
| `bal SGD 15.59` | Prepaid credit balance — hidden at zero | cookie helper |

**Colours:** green → amber (≥50%) → red (≥80%). Empty segments are dropped, so the line only ever shows what applies to you.

### Model name from the transcript, not the payload

`.model.display_name` in the piped JSON can lie: opening `/model` and cancelling the confirmation still updates it. The script instead reads the tail of the session transcript — every assistant message carries the model id that produced it, and a confirmed `/model` switch logs a `Set model to …` event — and prettifies the id (`claude-fable-5` → `Fable 5`). Brand-new sessions fall back to the payload until the first response.

### Effort level

Claude Code 2.1.x pipes the live level as `.effort.level`, including `max` (which is session-only and never written to `settings.json`). On older builds the field is absent and the script falls back to `.effortLevel` in `~/.claude/settings.json`, where `max` isn't observable.

### Plan usage: two sources, merged

1. **Native** — Claude Code ≥ 2.1 pipes `.rate_limits.{five_hour,seven_day}` from the session's own response headers. No cookies, no Python deps, works for any claude.ai subscriber on any platform. Limitations: absent until the first response of a session, and blind to usage from *other* concurrent sessions until this one makes its next call.
2. **Cookie helper** (`statusline-usage.py`) — decrypts the Claude desktop app's claude.ai session cookie and polls the org usage endpoint, cached 5 minutes. The only source for the model-scoped cap and the prepaid balance, and it fills the 5h/7d gap before the first response.

Native wins for 5h/7d whenever present; the helper is authoritative for everything else. Without the helper you still get 5h/7d — just not `fable`/`bal`.

### Knowledge-graph and council segments (optional, self-guarding)

Two extra chips exist for a local Obsidian knowledge-graph pipeline (`~/.claude-automation`). Both render nothing unless that directory exists, so they're invisible for everyone else:

- `⇄ ObsKG …` — **alert-only**: red `build failed` if the last vault build errored, red `RAG stale` if the vector store has fallen more than 6h behind `graph.json`. Silent when healthy.
- `⚖ council: ✓` / `⚖ council: 2 queued` / `⚖ council: no run` — did the nightly review run, and is there anything waiting.

## Requirements

- [Claude Code](https://claude.ai/code) ≥ 2.1 for the native effort/usage/PR fields (older builds still work, with fewer segments)
- `jq`, `python3`
- For the cookie helper (`fable` cap + balance): macOS, the Claude desktop app signed in to claude.ai, and `pycryptodome` + `curl_cffi` installed into **the interpreter the statusline runs** — `/usr/local/bin/python3` (framework Python) if it exists, else `python3`. The installer handles this, including Homebrew's PEP 668 refusal.

## Install

```sh
git clone https://github.com/pynzhern/claude-statusline
cd claude-statusline
chmod +x install.sh
./install.sh
```

Then restart Claude Code. If the Python deps fail to install you'll get a warning rather than an abort — the statusline still works on native data.

## How it works

Claude Code runs `statusline-command.sh` on every response and every 60 s, passing a JSON blob on stdin. The script:

1. Parses everything it needs in one `jq` call
2. Resolves the model from the transcript tail
3. Calls `statusline-usage.py` (cached) and overlays native `rate_limits` on top
4. Builds the bars in pure shell (10 segments × 8 fractional steps ≈ 1.25% resolution)
5. Measures the plain-text width against `COLUMNS` and emits one line if it fits, otherwise two

### Fetching plan usage (helper)

On macOS the helper reads the Electron AES key from Keychain (`Claude Safe Storage`), derives a 16-byte key via PBKDF2-SHA1 (1003 iterations), decrypts the `v10`-prefixed cookie, then calls:

- `/api/organizations/{org_id}/usage` — 5h/7d windows and the `limits[]` array (where the model-scoped cap lives, keyed by `kind == "weekly_scoped"`)
- `/api/organizations/{org_id}/prepaid/credits` — prepaid balance

Results cache to `/tmp/claude_usage_cache.json` for 5 minutes. A `Stop` hook zeroes `_cached_at` after every response so the next render re-fetches, keeping stale values as a fallback if the request fails. The cache also self-invalidates the moment any window's `resets_at` passes.

## Platform support

| Platform | Native 5h/7d, effort, PR, ctx | Cookie helper (`fable`, `bal`) |
|---|---|---|
| macOS | ✅ | ✅ |
| Linux | ✅ | ❌ cookie path and keyring differ |
| Windows | ✅ (untested) | ❌ DPAPI cookie decryption differs |

## Customisation

Thresholds, colours and the separator are set at the top of `statusline-command.sh`. Bars are fixed at 10 segments.

| Variable | Used for |
|---|---|
| `CYAN` | Working directory |
| `BLUE` | Git branch |
| `PURPLE` | Model name |
| `GRAY` | Effort level, draft PRs |
| `GREEN` / `AMBER` / `RED` | Usage < 50% / 50–79% / ≥ 80%, PR review state |
| `WHITE` | Credit balance |
