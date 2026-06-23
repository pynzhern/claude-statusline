#!/bin/sh
# claude-statusline: renders the Claude Code statusline on every refresh.
# runs on every response + every 60s, so minimise subshells and forks.

# ── parse session JSON in a single jq call ────────────────────────────────────
# jq emits four fields separated by newlines (one per line); we use
# newlines instead of tabs because POSIX `read` treats leading tabs as
# IFS whitespace and would collapse empty fields.
{
  IFS= read -r cwd
  IFS= read -r model
  IFS= read -r used
  IFS= read -r session_id
  IFS= read -r transcript
} <<EOF
$(jq -r '
    (.cwd // .workspace.current_dir // ""),
    (.model.display_name // ""),
    (.context_window.used_percentage // 0),
    (.session_id // ""),
    (.transcript_path // "")
  ')
EOF

# ── model ground truth from the transcript ────────────────────────────────────
# .model.display_name in the piped JSON can lie: opening the /model picker and
# cancelling the confirmation still updates it (e.g. shows "Opus 4.8" while the
# session is actually still on Fable 5). the transcript JSONL records the truth:
#   - every assistant message carries the model id that actually produced it
#   - a CONFIRMED /model switch logs a system local_command event whose stdout
#     says "Set model to <name> …" (cancelled/failed switches never get that
#     stdout), so a confirmed switch shows instantly with no one-message lag.
# whichever of the two appears last in the transcript wins. only the tail is
# scanned to keep the hot path cheap; brand-new sessions with no assistant
# message yet fall back to the (then-correct) piped display name.
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  _mid=$(tail -n 200 "$transcript" 2>/dev/null \
    | jq -r '
        if .type == "assistant" then (.message.model // empty)
        elif .type == "system" and .subtype == "local_command" then
          (.content // "" | gsub("<[^>]*>"; "")
            | try (capture("Set model to (?<m>.*?)(?: and saved.*)?$").m) // empty)
        else empty end' 2>/dev/null \
    | tail -n 1)
  if [ -n "$_mid" ]; then
    # prettify the id: claude-opus-4-8-20250101 → "Opus 4.8"
    model=$(printf '%s' "$_mid" | sed -E '
      s/^claude-//;
      s/-[0-9]{8}$//;
      s/-([0-9]+)-([0-9]+)$/ \1.\2/;
      s/-([0-9]+)$/ \1/;
      s/-/ /g')
    # capitalise each word (Fable 5, Opus 4.8, Sonnet 4.6 …)
    model=$(printf '%s' "$model" | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)} 1')
  fi
fi

folder=""
branch=""
if [ -n "$cwd" ]; then
  folder=$(basename "$cwd")

  # ── git branch with dirty indicator ─────────────────────────────────────────
  # `status --porcelain` covers tracked + untracked; match the original
  # behaviour where any new file triggers the `*` marker.
  branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null)
  if [ -n "$branch" ] && [ -n "$(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null)" ]; then
    branch="${branch}*"
  fi
fi

# effort level is not in the session JSON, so we assemble it from two sources
# with a clear priority order:
#   1. /tmp/claude-effort-<session_id> — written by the UserPromptSubmit hook
#      (effort-hook.sh) when the user types `/effort max`. max is session-only
#      in Claude Code and never touches settings.json, so the hook is the only
#      way the statusline can observe it.
#   2. .effortLevel in ~/.claude/settings.json — the persistent default, which
#      covers low/medium/high/xhigh/auto (all of which Claude Code persists).
# using `read < file` avoids a `cat` fork on the hot path.
effort=""
if [ -n "$session_id" ]; then
  _marker="/tmp/claude-effort-${session_id}"
  [ -f "$_marker" ] && IFS= read -r effort < "$_marker" 2>/dev/null || true
fi
[ -z "$effort" ] && effort=$(jq -r '.effortLevel // ""' ~/.claude/settings.json 2>/dev/null)

# ── ANSI colour codes ─────────────────────────────────────────────────────────
ESC=$(printf '\033')
GREEN="${ESC}[32m"
AMBER="${ESC}[38;5;214m"
RED="${ESC}[31m"
CYAN="${ESC}[36m"
BLUE="${ESC}[38;5;75m"
PURPLE="${ESC}[38;5;141m"
WHITE="${ESC}[97m"
GRAY="${ESC}[38;5;245m"
RESET="${ESC}[0m"

# ── percentage helpers (pure shell, no bc/awk forks) ──────────────────────────
# render_bar <pct> <warn> <danger> — builds a coloured 10-segment bar.
# sets the globals `col` (threshold colour) and `bar` (the rendered bar
# string with ANSI codes) to avoid command-substitution subshells on the
# hot path. inputs may be floats (e.g. 17.5); we truncate to an int for
# comparison which is fine for the coarse 50/80 thresholds used throughout.
# 10 segments × 8 unicode sub-steps = 80 effective levels (~1.25% per step).
# filled segments use ▓, the transition uses a fractional block (▏▎▍▌▋▊▉),
# and empty segments use ░ — total bar width stays exactly 10 characters.
render_bar() {
  _p=${1%%.*}; [ -z "$_p" ] && _p=0
  if   [ "$_p" -ge "$3" ]; then col="$RED"
  elif [ "$_p" -ge "$2" ]; then col="$AMBER"
  else                          col="$GREEN"
  fi
  _total=$(( _p * 4 / 5 ))
  [ "$_total" -gt 80 ] && _total=80
  _filled=$(( _total / 8 ))
  _frac=$(( _total % 8 ))
  case "$_frac" in
    1) _part="▏" ;; 2) _part="▎" ;; 3) _part="▍" ;;
    4) _part="▌" ;; 5) _part="▋" ;; 6) _part="▊" ;; 7) _part="▉" ;;
    *) _part="" ;;
  esac
  [ -n "$_part" ] && _partial=1 || _partial=0
  _empty=$(( 10 - _filled - _partial ))
  _body=""
  _i=0; while [ $_i -lt $_filled ]; do _body="${_body}█"; _i=$((_i+1)); done
  _body="${_body}${_part}"
  _i=0; while [ $_i -lt $_empty  ]; do _body="${_body} "; _i=$((_i+1)); done
  bar="${col}${_body}${RESET}"
}

# ── context window bar ────────────────────────────────────────────────────────
render_bar "$used" 50 80
ctx_str="${col}ctx ${used%.*}%${RESET} [${bar}]"
ctx_p="ctx ${used%.*}% [          ]"

# ── effort level indicator ────────────────────────────────────────────────────
if [ -n "$effort" ]; then
  effort_str="${GRAY}${effort}${RESET}"
  effort_p="$effort"
else
  effort_str=""; effort_p=""
fi

# ── claude plan usage (cached via python helper, 5-min TTL) ───────────────────
# the helper needs pycryptodome + curl_cffi to decrypt the claude.ai cookie and
# fetch usage. those live in the framework python (3.11), NOT in brew's bare
# `python3` (3.14+ after a homebrew upgrade ships an empty site-packages and
# orphans every pip package). pin to the interpreter that has the deps, falling
# back to bare python3 so a fresh machine still runs (it just shows stale usage).
USAGE_PY=/usr/local/bin/python3
[ -x "$USAGE_PY" ] || USAGE_PY=python3
# parse all six usage fields in a single jq call; newline-delimited output
# so empty fields are preserved by POSIX `read`.
{
  IFS= read -r five_pct
  IFS= read -r five_reset
  IFS= read -r seven_pct
  IFS= read -r seven_reset
  IFS= read -r bal
  IFS= read -r cur
} <<EOF
$("$USAGE_PY" ~/.claude/statusline-usage.py 2>/dev/null | jq -r '
    (.five_hour_pct       // ""),
    (.five_hour_resets_in // ""),
    (.seven_day_pct       // ""),
    (.seven_day_resets_in // ""),
    (.prepaid_balance     // ""),
    (.prepaid_currency    // "SGD")
  ' 2>/dev/null)
EOF

# 5-hour session bar
if [ -n "$five_pct" ]; then
  render_bar "$five_pct" 50 80
  five_str="${col}5h ${five_pct}%${RESET} [${bar}]"
  five_p="5h ${five_pct}% [          ]"
  if [ -n "$five_reset" ]; then
    five_str="${five_str} ${col}↻${five_reset}${RESET}"
    five_p="${five_p} ↻${five_reset}"
  fi
else
  five_str=""; five_p=""
fi

# 7-day weekly bar
if [ -n "$seven_pct" ]; then
  render_bar "$seven_pct" 50 80
  seven_str="${col}7d ${seven_pct}%${RESET} [${bar}]"
  seven_p="7d ${seven_pct}% [          ]"
  if [ -n "$seven_reset" ]; then
    seven_str="${seven_str} ${col}↻${seven_reset}${RESET}"
    seven_p="${seven_p} ↻${seven_reset}"
  fi
else
  seven_str=""; seven_p=""
fi

# prepaid credit balance — hidden at exactly 0.00 (no signal, just width)
if [ -n "$bal" ] && [ "$bal" != "0.00" ] && [ "$bal" != "0" ]; then
  extra_str="${WHITE}bal ${cur} ${bal}${RESET}"
  extra_p="bal ${cur} ${bal}"
else
  extra_str=""; extra_p=""
fi

# ── obsidian knowledge-graph health (alert-only) ─────────────────────────────
# Silent when healthy: the auto-refresh runs every active turn, so a permanent
# "ObsKG just now" chip was pure noise AND blind to the failure that actually
# bit (the RAG reindex died silently for ~18 days while the vault kept building).
# Now it only speaks up in red, for the two real failure modes:
#   1. the most recent vault build failed/timed out, OR
#   2. the RAG store fell behind graph.json (reindex is failing) — the tripwire
#      that would have caught this week's bug.
kg_str=""; kg_p=""
_kglog="$HOME/.claude-automation/auto-refresh.log"
_gj="$HOME/.claude-automation/graph.json"
_vec="$HOME/.claude-automation/rag/store/vectors.npy"
_kgevent=$(grep -E "refresh cc:|BUILD (FAILED|TIMED OUT)" "$_kglog" 2>/dev/null | tail -1)
case "$_kgevent" in
  *"BUILD FAILED"*|*"TIMED OUT"*)
    kg_str="${RED}⇄ ObsKG build failed${RESET}"; kg_p="⇄ ObsKG build failed" ;;
esac
if [ -z "$kg_str" ] && [ -f "$_gj" ] && [ -f "$_vec" ]; then
  _gjm=$(stat -f %m "$_gj" 2>/dev/null); _vm=$(stat -f %m "$_vec" 2>/dev/null)
  if [ -n "$_gjm" ] && [ -n "$_vm" ] && [ $(( _gjm - _vm )) -gt 21600 ]; then
    kg_str="${RED}⇄ ObsKG RAG stale${RESET}"; kg_p="⇄ ObsKG RAG stale"
  fi
fi

# ── council status (KG self-update) ───────────────────────────────────────────
# Minimal: a single '⚖ council: ✓' confirms the nightly 3am run happened and is
# clean (pz wants a quick "it ran, not cocked up", not a verbose chip lingering
# all day). It gets loud only when there's something to do or something's wrong:
#   amber ⚖ council: N to review  — items queued (run review.py)
#   red   ⚖ council: no run       — no run in >30h (a night was skipped)
# "did it run + when" uses .last_run.json .ts (the structured heartbeat phase2
# writes on EVERY --daily run, incl. quiet no-op nights), with dryrun.log mtime
# (the launchd StandardOutPath, bumped on every execution) as a fallback — take
# whichever is fresher so a missing/lagging heartbeat never trips a false alarm.
# ⚖ (judgement) stays distinct from ObsKG's ⇄.
council_str=""; council_p=""
_cqueue="$HOME/.claude-automation/council/pending_review/QUEUE.jsonl"
_crun="$HOME/.claude-automation/council/.last_run.json"
_clog="$HOME/.claude-automation/council/dryrun.log"
_creview=0
[ -f "$_cqueue" ] && _creview=$(grep -c '' "$_cqueue" 2>/dev/null)
: "${_creview:=0}"
_cage=999999
if [ -f "$_crun" ]; then
  _cts=$(jq -r '.ts // ""' "$_crun" 2>/dev/null)
  if [ -n "$_cts" ]; then
    _ce=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$_cts" +%s 2>/dev/null)
    [ -n "$_ce" ] && _cage=$(( $(date +%s) - _ce ))
  fi
fi
if [ -f "$_clog" ]; then
  _cm=$(stat -f %m "$_clog" 2>/dev/null)
  if [ -n "$_cm" ]; then _la=$(( $(date +%s) - _cm )); [ "$_la" -lt "$_cage" ] && _cage=$_la; fi
fi
if [ "$_cage" -gt 108000 ]; then
  council_str="${RED}⚖ council: no run${RESET}"; council_p="⚖ council: no run"
elif [ "$_creview" -gt 0 ] 2>/dev/null; then
  council_str="${AMBER}⚖ council: ${_creview} to review${RESET}"; council_p="⚖ council: ${_creview} to review"
else
  council_str="${GREEN}⚖ council: ✓${RESET}"; council_p="⚖ council: ✓"
fi

SEP="  ·  "

# ── assemble output ───────────────────────────────────────────────────────────
# build colored (c) and plain (p) versions in parallel; measuring plain length
# via ${#} avoids an ANSI-stripping fork. if everything fits in $COLUMNS we
# emit one line, otherwise we fall back to the natural two-line split.
l1c=""; l1p=""
l2c=""; l2p=""
add1() {
  [ -z "$1" ] && return
  if [ -z "$l1c" ]; then l1c="$1"; l1p="$2"
  else l1c="${l1c}${SEP}$1"; l1p="${l1p}${SEP}$2"; fi
}
add2() {
  [ -z "$1" ] && return
  if [ -z "$l2c" ]; then l2c="$1"; l2p="$2"
  else l2c="${l2c}${SEP}$1"; l2p="${l2p}${SEP}$2"; fi
}

add1 "${folder:+${CYAN}${folder}${RESET}}" "$folder"
add1 "${branch:+${BLUE}${branch}${RESET}}" "$branch"
add1 "${model:+${PURPLE}${model}${RESET}}" "$model"
add1 "$effort_str" "$effort_p"
add1 "$ctx_str" "$ctx_p"
add1 "$kg_str" "$kg_p"
add1 "$council_str" "$council_p"

add2 "$five_str" "$five_p"
add2 "$seven_str" "$seven_p"
add2 "$extra_str" "$extra_p"

# join into one candidate line, compare visible width against terminal width
if [ -n "$l2c" ]; then
  full_c="${l1c}${SEP}${l2c}"; full_p="${l1p}${SEP}${l2p}"
else
  full_c="$l1c"; full_p="$l1p"
fi

# prefer COLUMNS (set by Claude Code when available), else read the actual
# controlling terminal width via stty (works even when stdin is redirected),
# else fall back to 0 which forces the safe two-line split.
term_w=${COLUMNS:-$(stty size 2>/dev/null </dev/tty | cut -d' ' -f2)}
: "${term_w:=0}"
# ⚖ renders ~2 cols but bash ${#} counts it as 1 — add the undercount back so a
# line that visually overflows the terminal still trips the two-line split
# instead of being clipped with an ellipsis by the host.
_wide=$(printf '%s' "$full_p" | grep -o '⚖' | wc -l | tr -d ' ')
vis_w=$(( ${#full_p} + _wide ))
# require a 2-col headroom rather than an exact fit: COLUMNS can overstate the
# usable statusline width by a column or two (host-reserved columns, the
# terminal's un-writable final cell, residual wide-glyph undercount), and at
# zero margin any of those clips the line with an ellipsis instead of wrapping.
if [ "$(( vis_w + 2 ))" -le "$term_w" ]; then
  printf '%s' "$full_c"
elif [ -n "$l2c" ]; then
  printf '%s\n%s' "$l1c" "$l2c"
else
  printf '%s' "$l1c"
fi
