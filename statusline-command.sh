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

# effort level is not in the session JSON; read the persistent setting.
# session-only overrides (/effort max etc.) are not visible to the statusline.
effort=$(jq -r '.effortLevel // ""' ~/.claude/settings.json 2>/dev/null)

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

# prepaid credit balance
if [ -n "$bal" ]; then
  extra_str="${WHITE}bal ${cur} ${bal}${RESET}"
  extra_p="bal ${cur} ${bal}"
else
  extra_str=""; extra_p=""
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
if [ "${#full_p}" -le "$term_w" ]; then
  printf '%s' "$full_c"
elif [ -n "$l2c" ]; then
  printf '%s\n%s' "$l1c" "$l2c"
else
  printf '%s' "$l1c"
fi
