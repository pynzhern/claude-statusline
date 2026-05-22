#!/bin/sh
# claude-statusline: UserPromptSubmit hook to track session-only `/effort max`.
#
# Claude Code does not persist `/effort max` to ~/.claude/settings.json
# (it's a session-only override). the other levels — low, medium, high,
# xhigh, auto — are persisted and thus visible to the statusline. this
# hook bridges the gap by writing a session-scoped marker file when max
# is typed, and removing it when any other effort level is typed (so the
# persistent setting takes over cleanly).
#
# the marker lives at /tmp/claude-effort-<session_id> and contains the
# literal string `max`. the statusline prefers the marker over the
# settings.json value. stale markers (>24h) are pruned opportunistically.

# deliberately no `set -e` — this is a UserPromptSubmit hook, and a non-zero
# exit can block the user's prompt. if anything fails (jq missing, malformed
# JSON, permission issues), we want to degrade silently and let the user
# carry on.

payload=$(cat)
session=$(printf '%s' "$payload" | jq -r '.session_id // ""' 2>/dev/null)
prompt=$( printf '%s' "$payload" | jq -r '.prompt     // ""' 2>/dev/null)

# without a session_id we can't scope the marker — bail out silently.
[ -z "$session" ] && exit 0

marker="/tmp/claude-effort-${session}"

# tolerant match: case-insensitive, allows leading/trailing/extra whitespace,
# anchored to the full prompt so "/effort max" inside a longer sentence
# (e.g. a question about the command) does not trip the detector.
if printf '%s' "$prompt" | grep -Eiq '^[[:space:]]*/effort[[:space:]]+max[[:space:]]*$'; then
  printf 'max' > "$marker"
elif printf '%s' "$prompt" | grep -Eiq '^[[:space:]]*/effort[[:space:]]+(low|medium|high|xhigh|auto)[[:space:]]*$'; then
  # switching to a persisted level — drop the session-only override so
  # settings.json becomes the source of truth again.
  rm -f "$marker"
fi

# opportunistic cleanup: prune markers older than 24h to keep /tmp tidy.
# runs on every prompt so no separate cron/SessionStart hook needed.
# note the trailing slash on /tmp/ — on macOS /tmp is a symlink to /private/tmp,
# and without the slash BSD find refuses to descend into it (so stale markers
# would never get pruned). the trailing slash dereferences the link portably
# on both Linux and macOS.
find /tmp/ -maxdepth 1 -name 'claude-effort-*' -type f -mtime +1 -delete 2>/dev/null || true

exit 0
