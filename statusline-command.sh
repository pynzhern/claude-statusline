#!/bin/sh
input=$(cat)

# folder: basename of cwd
cwd=$(echo "$input" | jq -r '.cwd // .workspace.current_dir // ""')
folder=$(basename "$cwd")

# git branch with dirty indicator
branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null)
if [ -n "$branch" ] && [ -n "$(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null)" ]; then
  branch="${branch}*"
fi

# model display name
model=$(echo "$input" | jq -r '.model.display_name // ""')

# context used percentage
used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')

# ANSI colour codes
GREEN=$(printf '\033[32m')
AMBER=$(printf '\033[38;5;214m')
RED=$(printf '\033[31m')
CYAN=$(printf '\033[36m')
BLUE=$(printf '\033[38;5;75m')
PURPLE=$(printf '\033[38;5;141m')
WHITE=$(printf '\033[97m')
RESET=$(printf '\033[0m')

# return the colour for a given percentage and thresholds
pct_colour() {
  pct="$1"; warn="$2"; danger="$3"
  is_danger=$(echo "$pct >= $danger" | bc -l 2>/dev/null || echo 0)
  is_warn=$(echo   "$pct >= $warn"   | bc -l 2>/dev/null || echo 0)
  if   [ "$is_danger" = "1" ]; then printf '%s' "$RED"
  elif [ "$is_warn"   = "1" ]; then printf '%s' "$AMBER"
  else                               printf '%s' "$GREEN"
  fi
}

# build a 10-char progress bar coloured by percentage thresholds
make_bar() {
  pct="$1"; warn="$2"; danger="$3"
  filled=$(printf '%.0f' "$(echo "$pct * 10 / 100" | bc -l 2>/dev/null || echo 0)")
  empty=$((10 - filled))
  colour=$(pct_colour "$pct" "$warn" "$danger")
  bar=""
  i=0; while [ $i -lt $filled ]; do bar="${bar}▓"; i=$((i+1)); done
  i=0; while [ $i -lt $empty  ]; do bar="${bar}░"; i=$((i+1)); done
  printf '%s' "${colour}${bar}${RESET}"
}

# --- context window (label + % in bar colour, bar itself coloured) ---
if [ -n "$used" ]; then
  col=$(pct_colour "$used" 50 80)
  bar=$(make_bar   "$used" 50 80)
  ctx_str="${col}ctx $(printf '%.0f' "$used")%${RESET} [${bar}]"
else
  # no messages yet (e.g. after /clear) — show empty bar at 0%
  empty_bar=$(make_bar 0 50 80)
  ctx_str="${GREEN}ctx 0%${RESET} [${empty_bar}]"
fi

# --- claude plan usage (cached via python helper, 5-min TTL) ---
usage_json=$(python3 ~/.claude/statusline-usage.py 2>/dev/null || echo '{}')

five_pct=$(echo   "$usage_json" | jq -r '.five_hour_pct       // empty')
five_reset=$(echo "$usage_json" | jq -r '.five_hour_resets_in // empty')
seven_pct=$(echo  "$usage_json" | jq -r '.seven_day_pct       // empty')
seven_reset=$(echo "$usage_json" | jq -r '.seven_day_resets_in // empty')
bal=$(echo        "$usage_json" | jq -r '.prepaid_balance     // empty')
cur=$(echo        "$usage_json" | jq -r '.prepaid_currency    // "SGD"')

# 5-hour session bar
if [ -n "$five_pct" ]; then
  col=$(pct_colour "$five_pct" 50 80)
  bar=$(make_bar   "$five_pct" 50 80)
  five_str="${col}5h ${five_pct}%${RESET} [${bar}]"
  [ -n "$five_reset" ] && five_str="${five_str} ${col}↻${five_reset}${RESET}"
else
  five_str=""
fi

# 7-day weekly bar
if [ -n "$seven_pct" ]; then
  col=$(pct_colour "$seven_pct" 50 80)
  bar=$(make_bar   "$seven_pct" 50 80)
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

# assemble
parts=""
[ -n "$folder"    ] && parts="${CYAN}${folder}${RESET}"
[ -n "$branch"    ] && parts="$parts${SEP}${BLUE}${branch}${RESET}"
[ -n "$model"     ] && parts="$parts${SEP}${PURPLE}${model}${RESET}"
[ -n "$ctx_str"   ] && parts="$parts${SEP}${ctx_str}"
[ -n "$five_str"  ] && parts="$parts${SEP}${five_str}"
[ -n "$seven_str" ] && parts="$parts${SEP}${seven_str}"
[ -n "$extra_str" ] && parts="$parts${SEP}${extra_str}"

printf '%s' "$parts"
