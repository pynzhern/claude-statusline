#!/bin/sh
# claude-statusline: renders the Claude Code statusline on every refresh.
# runs on every response + every 60s, so minimise subshells and forks.

# ── parse session JSON in a single jq call ────────────────────────────────────
# jq emits three fields separated by newlines (one per line); we use
# newlines instead of tabs because POSIX `read` treats leading tabs as
# IFS whitespace and would collapse empty fields.
{
  IFS= read -r cwd
  IFS= read -r model
  IFS= read -r used
} <<EOF
$(jq -r '
    (.cwd // .workspace.current_dir // ""),
    (.model.display_name // ""),
    (.context_window.used_percentage // 0)
  ')
EOF

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

# ── ANSI colour codes ─────────────────────────────────────────────────────────
ESC=$(printf '\033')
GREEN="${ESC}[32m"
AMBER="${ESC}[38;5;214m"
RED="${ESC}[31m"
CYAN="${ESC}[36m"
BLUE="${ESC}[38;5;75m"
PURPLE="${ESC}[38;5;141m"
WHITE="${ESC}[97m"
RESET="${ESC}[0m"

# ── percentage helpers (pure shell, no bc/awk forks) ──────────────────────────
# render_bar <pct> <warn> <danger> — builds a coloured 10-segment bar.
# sets the globals `col` (threshold colour) and `bar` (the rendered bar
# string with ANSI codes) to avoid command-substitution subshells on the
# hot path. inputs may be floats (e.g. 17.5); we truncate to an int for
# comparison which is fine for the coarse 50/80 thresholds used throughout.
# filled segments are rounded to the nearest 10% and clamped to [0,10]
# so utilisation > 100% still renders a full bar.
render_bar() {
  _p=${1%%.*}; [ -z "$_p" ] && _p=0
  if   [ "$_p" -ge "$3" ]; then col="$RED"
  elif [ "$_p" -ge "$2" ]; then col="$AMBER"
  else                          col="$GREEN"
  fi
  _filled=$(( (_p + 5) / 10 ))
  [ "$_filled" -lt 0  ] && _filled=0
  [ "$_filled" -gt 10 ] && _filled=10
  _empty=$(( 10 - _filled ))
  # build the bar with two POSIX-safe loops; fast enough at n≤10.
  _body=""
  _i=0; while [ $_i -lt $_filled ]; do _body="${_body}▓"; _i=$((_i+1)); done
  _i=0; while [ $_i -lt $_empty  ]; do _body="${_body}░"; _i=$((_i+1)); done
  bar="${col}${_body}${RESET}"
}

# ── context window bar ────────────────────────────────────────────────────────
render_bar "$used" 50 80
ctx_str="${col}ctx ${used%.*}%${RESET} [${bar}]"

# ── claude plan usage (cached via python helper, 5-min TTL) ───────────────────
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
$(python3 ~/.claude/statusline-usage.py 2>/dev/null | jq -r '
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
  [ -n "$five_reset" ] && five_str="${five_str} ${col}↻${five_reset}${RESET}"
else
  five_str=""
fi

# 7-day weekly bar
if [ -n "$seven_pct" ]; then
  render_bar "$seven_pct" 50 80
  seven_str="${col}7d ${seven_pct}%${RESET} [${bar}]"
  [ -n "$seven_reset" ] && seven_str="${seven_str} ${col}↻${seven_reset}${RESET}"
else
  seven_str=""
fi

# prepaid credit balance
if [ -n "$bal" ]; then
  extra_str="${WHITE}bal ${cur} ${bal}${RESET}"
else
  extra_str=""
fi

SEP="  ·  "

# ── assemble output ───────────────────────────────────────────────────────────
# `add` appends a segment with the separator, but only after the first
# non-empty segment has been set, so we never emit a leading `  ·  `.
parts=""
add() {
  [ -z "$1" ] && return
  if [ -z "$parts" ]; then
    parts="$1"
  else
    parts="${parts}${SEP}$1"
  fi
}

add "${folder:+${CYAN}${folder}${RESET}}"
add "${branch:+${BLUE}${branch}${RESET}}"
add "${model:+${PURPLE}${model}${RESET}}"
add "$ctx_str"
add "$five_str"
add "$seven_str"
add "$extra_str"

printf '%s' "$parts"
