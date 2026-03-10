#!/bin/bash
# Claude Code Status Line — v6 SF Console HUD
input=$(cat)

# ── Colors ──
C='\033[36m'   # cyan
CH='\033[96m'  # bright cyan
M='\033[35m'   # magenta
G='\033[32m'   # green
GH='\033[92m'  # bright green
Y='\033[33m'   # yellow
R='\033[31m'   # red
D='\033[2m'    # dim
B='\033[1m'    # bold
X='\033[0m'    # reset

# ── Terminal width ──
COLS=${COLUMNS:-$(tput cols 2>/dev/null || echo 120)}

# ── Extract all JSON fields in one jq call ──
eval "$(echo "$input" | jq -r '
  @sh "MODEL=\(.model.display_name // "")",
  @sh "DIR=\(.workspace.current_dir // "")",
  @sh "PCT=\(.context_window.used_percentage // 0 | floor)",
  @sh "COST=\(.cost.total_cost_usd // 0)",
  @sh "DURATION_MS=\(.cost.total_api_duration_ms // 0 | floor)",
  @sh "TOTAL_DUR_MS=\(.cost.total_duration_ms // 0 | floor)",
  @sh "LINES_ADD=\(.cost.total_lines_added // 0)",
  @sh "LINES_DEL=\(.cost.total_lines_removed // 0)",
  @sh "TOTAL_IN_TOK=\(.context_window.total_input_tokens // 0)",
  @sh "TOTAL_OUT_TOK=\(.context_window.total_output_tokens // 0)",
  @sh "CACHE_READ=\(.context_window.current_usage.cache_read_input_tokens // 0)",
  @sh "STYLE=\(.output_style.name // "")",
  @sh "TRANSCRIPT=\(.transcript_path // "")",
  @sh "AGENT=\(.agent.name // "")",
  @sh "WT_NAME=\(.worktree.name // "")",
  @sh "VIM_MODE=\(.vim.mode // "")"
')"

# ── Git cache (5s TTL) ──
CACHE="/tmp/claude-sl-git"
file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

if [ ! -f "$CACHE" ] || [ $(($(date +%s) - $(file_mtime "$CACHE"))) -gt 5 ]; then
  if git rev-parse --git-dir > /dev/null 2>&1; then
    _b=$(git branch --show-current 2>/dev/null)
    _s=$(git diff --cached --numstat 2>/dev/null | wc -l | tr -d ' ')
    _m=$(git diff --numstat 2>/dev/null | wc -l | tr -d ' ')
    _r=$(git remote get-url origin 2>/dev/null \
      | sed 's|git@github\.com:|https://github.com/|;s|\.git$||')
    echo "${_b}|${_s}|${_m}|${_r}" > "$CACHE"
  else
    echo "|||" > "$CACHE"
  fi
fi
IFS='|' read -r BRANCH STAGED MODIFIED REMOTE < "$CACHE"

# ── Transcript cache (10s TTL) — session name + effort ──
TR_CACHE="/tmp/claude-sl-transcript"
SESSION_NAME=""
TR_EFFORT=""

if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  if [ ! -f "$TR_CACHE" ] || [ $(($(date +%s) - $(file_mtime "$TR_CACHE"))) -gt 10 ]; then
    _sname=""
    _effort=""
    # Read transcript backwards for most recent entries
    _reversed=$(tac "$TRANSCRIPT" 2>/dev/null || tail -r "$TRANSCRIPT" 2>/dev/null)
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      if [ -z "$_sname" ]; then
        _try=$(echo "$line" | jq -r 'select(.type=="custom-title") | .customTitle // empty' 2>/dev/null)
        [ -n "$_try" ] && _sname="$_try"
      fi
      if [ -z "$_effort" ]; then
        _try=$(echo "$line" | jq -r '.message.content // empty' 2>/dev/null)
        if [ -n "$_try" ]; then
          # Strip ANSI codes, then match effort pattern
          _clean=$(echo "$_try" | sed 's/\x1b\[[0-9;]*m//g')
          _match=$(echo "$_clean" | grep -oP 'with \K(low|medium|high|max)(?= effort)' 2>/dev/null \
                || echo "$_clean" | sed -n 's/.*with \(low\|medium\|high\|max\) effort.*/\1/p')
          [ -n "$_match" ] && _effort="$_match"
        fi
      fi
      [ -n "$_sname" ] && [ -n "$_effort" ] && break
    done <<< "$_reversed"
    echo "${_sname}|${_effort}" > "$TR_CACHE"
  fi
  IFS='|' read -r SESSION_NAME TR_EFFORT < "$TR_CACHE"
fi

# ── Effort: transcript > settings.json > output_style ──
EFFORT=""
if [ -n "$TR_EFFORT" ]; then
  EFFORT="$TR_EFFORT"
elif [ -z "$EFFORT" ]; then
  CLAUDE_CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
  if [ -f "$CLAUDE_CFG" ]; then
    _se=$(jq -r '.effortLevel // empty' "$CLAUDE_CFG" 2>/dev/null)
    [ -n "$_se" ] && EFFORT="$_se"
  fi
fi
if [ -z "$EFFORT" ] && [ -n "$STYLE" ] && [ "$STYLE" != "default" ]; then
  EFFORT="$STYLE"
fi

# ── Usage API cache (180s TTL) — 5h reset timer ──
USAGE_CACHE="${HOME}/.cache/claude-sl/usage.json"
USAGE_LOCK="${HOME}/.cache/claude-sl/usage.lock"
API_UTIL=""
API_RESET=""

fetch_usage_api() {
  # Get OAuth token
  local cred_file="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json"
  local token=""
  if [ -f "$cred_file" ]; then
    token=$(jq -r '.claudeAiOauth.accessToken // empty' "$cred_file" 2>/dev/null)
  fi
  # macOS keychain fallback
  if [ -z "$token" ] && command -v security &>/dev/null; then
    token=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
      | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
  fi
  [ -z "$token" ] && return 1

  local resp
  resp=$(curl -sf --max-time 5 \
    -H "Authorization: Bearer $token" \
    -H "anthropic-beta: oauth-2025-04-20" \
    "https://api.anthropic.com/api/oauth/usage" 2>/dev/null) || return 1

  mkdir -p "$(dirname "$USAGE_CACHE")"
  echo "$resp" > "$USAGE_CACHE"
}

# Fetch if cache is stale (180s) and no lock held (<30s old)
if [ ! -f "$USAGE_CACHE" ] || [ $(($(date +%s) - $(file_mtime "$USAGE_CACHE"))) -gt 180 ]; then
  if [ ! -f "$USAGE_LOCK" ] || [ $(($(date +%s) - $(file_mtime "$USAGE_LOCK"))) -gt 30 ]; then
    mkdir -p "$(dirname "$USAGE_LOCK")"
    touch "$USAGE_LOCK"
    fetch_usage_api
    rm -f "$USAGE_LOCK"
  fi
fi

# Read cached usage data
if [ -f "$USAGE_CACHE" ]; then
  eval "$(jq -r '
    @sh "API_UTIL=\(.five_hour.utilization // "")",
    @sh "API_RESET=\(.five_hour.resets_at // "")"
  ' "$USAGE_CACHE" 2>/dev/null)"
fi

# ── Helper: format token count (K/M) ──
fmt_tok() {
  local n=$1
  if [ "$n" -ge 1000000 ] 2>/dev/null; then
    printf '%.1fM' "$(echo "scale=1; $n / 1000000" | bc 2>/dev/null || echo 0)"
  elif [ "$n" -ge 1000 ] 2>/dev/null; then
    printf '%.1fK' "$(echo "scale=1; $n / 1000" | bc 2>/dev/null || echo 0)"
  else
    echo "$n"
  fi
}

# ── Helper: format duration ──
fmt_dur() {
  local ms=$1
  local total_s=$((ms / 1000))
  local h=$((total_s / 3600))
  local m=$(( (total_s % 3600) / 60 ))
  local s=$((total_s % 60))
  if [ "$h" -gt 0 ]; then
    printf '%dh%02dm' "$h" "$m"
  elif [ "$m" -gt 0 ]; then
    printf '%dm%02ds' "$m" "$s"
  else
    printf '%ds' "$s"
  fi
}

# ── Computed values ──
# Output speed (tok/s)
OUT_TOKS=0
if [ "$DURATION_MS" -gt 0 ] 2>/dev/null && [ "$TOTAL_OUT_TOK" -gt 0 ] 2>/dev/null; then
  OUT_TOKS=$((TOTAL_OUT_TOK * 1000 / DURATION_MS))
fi

# Token totals
IN_FMT=$(fmt_tok "$TOTAL_IN_TOK")
OUT_FMT=$(fmt_tok "$TOTAL_OUT_TOK")
CACHE_FMT=$(fmt_tok "$CACHE_READ")

# Session elapsed time
SESSION_ELAPSED=$(fmt_dur "$TOTAL_DUR_MS")

# 5-hour reset timer: API first, fallback to session elapsed
if [ -n "$API_UTIL" ] && [ -n "$API_RESET" ]; then
  # API provides utilization % and reset timestamp
  USAGE_PCT=$(printf '%.0f' "$API_UTIL" 2>/dev/null || echo 0)
  # Calculate remaining time from reset timestamp
  RESET_EPOCH=$(date -d "$API_RESET" +%s 2>/dev/null \
    || date -jf "%Y-%m-%dT%H:%M:%S" "$(echo "$API_RESET" | sed 's/\.[0-9]*Z$//')" +%s 2>/dev/null \
    || echo 0)
  NOW_EPOCH=$(date +%s)
  REMAINING_S=$(( RESET_EPOCH > NOW_EPOCH ? RESET_EPOCH - NOW_EPOCH : 0 ))
  RESET_H=$((REMAINING_S / 3600))
  RESET_M=$(( (REMAINING_S % 3600) / 60 ))
  RESET_DISP=$(printf '%dh%02dm' "$RESET_H" "$RESET_M")
  USAGE_DISP="${USAGE_PCT}%"
else
  # Fallback: estimate from session duration
  USAGE_PCT=""
  RESET_WINDOW_MS=$((5 * 3600 * 1000))
  REMAINING_MS=$((RESET_WINDOW_MS - TOTAL_DUR_MS))
  [ "$REMAINING_MS" -lt 0 ] && REMAINING_MS=0
  REMAINING_S=$((REMAINING_MS / 1000))
  RESET_H=$((REMAINING_S / 3600))
  RESET_M=$(( (REMAINING_S % 3600) / 60 ))
  RESET_DISP="~$(printf '%dh%02dm' "$RESET_H" "$RESET_M")"
  USAGE_DISP=""
fi

# Reset timer color
if [ "$REMAINING_S" -le 3600 ]; then
  RC="$R"
elif [ "$REMAINING_S" -le 7200 ]; then
  RC="$Y"
else
  RC="$G"
fi

# API duration
MINS=$((DURATION_MS / 60000))
SECS=$(( (DURATION_MS % 60000) / 1000 ))

# Bar color
if [ "$PCT" -ge 90 ]; then BC="$R"
elif [ "$PCT" -ge 70 ]; then BC="$Y"
else BC="$G"; fi

# Cost
COST_FMT=$(printf '$%.2f' "$COST")
COST_INT=${COST%%.*}
if [ "${COST_INT:-0}" -ge 1 ] 2>/dev/null; then CC="$R"; else CC="$Y"; fi

SEP="${D}│${X}"

# ══════════════════════════════════════════════════════
# ── Width-adaptive layout ──
# ══════════════════════════════════════════════════════
# Full (≥120): everything
# Medium (80–119): hide API duration, code changes
# Narrow (60–79): also hide cost, speed, tokens
# Minimal (<60): only context bar + model

# ── Line 1: ❮ Model ❯ [effort] "session" ── dir ──  branch +S ~M ──
LINE1="${C}❮${X} ${CH}${MODEL}${X}"
[ -n "$AGENT" ] && LINE1="${LINE1} ${D}${AGENT}${X}"
[ -n "$VIM_MODE" ] && LINE1="${LINE1} ${D}${VIM_MODE}${X}"
[ -n "$EFFORT" ] && LINE1="${LINE1} ${D}[${EFFORT}]${X}"
LINE1="${LINE1} ${C}❯${X}"

# Session name (from /rename)
if [ -n "$SESSION_NAME" ] && [ "$COLS" -ge 80 ]; then
  LINE1="${LINE1} ${C}\"${SESSION_NAME}\"${X}"
fi

# Directory
if [ "$COLS" -ge 60 ]; then
  LINE1="${LINE1} ${D}──${X} ${DIR##*/}"
fi

# Git branch
if [ -n "$BRANCH" ] && [ "$COLS" -ge 60 ]; then
  LINE1="${LINE1} ${D}──${X} "
  [ -n "$WT_NAME" ] && LINE1="${LINE1}${D}WT${X} "
  if [ -n "$REMOTE" ]; then
    LINE1="${LINE1}\033]8;;${REMOTE}/tree/${BRANCH}\a${M}\ue0a0 ${BRANCH}${X}\033]8;;\a"
  else
    LINE1="${LINE1}${M}\ue0a0 ${BRANCH}${X}"
  fi
  [ "$STAGED" -gt 0 ] 2>/dev/null && LINE1="${LINE1} ${GH}+${STAGED}${X}"
  [ "$MODIFIED" -gt 0 ] 2>/dev/null && LINE1="${LINE1} ${Y}~${MODIFIED}${X}"
fi

# ── Line 2: context bar │ tokens │ speed │ cost │ usage/timer │ code │ api ──
BAR_W=10
FULL=$((PCT * BAR_W / 100))
EMPTY=$((BAR_W - FULL))
BAR=""
for ((i=0; i<FULL; i++)); do BAR="${BAR}▰"; done
for ((i=0; i<EMPTY; i++)); do BAR="${BAR}▱"; done

# Always show: context bar
LINE2="${BC}${BAR}${X} ${BC}${PCT}%${X}"

# Usage/timer segment
TIMER_SEG="${D}${SESSION_ELAPSED}${X} ${RC}⏳${RESET_DISP}${X}"
[ -n "$USAGE_DISP" ] && TIMER_SEG="${RC}${USAGE_DISP}${X} ${TIMER_SEG}"

if [ "$COLS" -ge 120 ]; then
  # Full width: everything
  LINE2="${LINE2} ${SEP} ${D}↑${IN_FMT} ↓${OUT_FMT} ⚡${CACHE_FMT}${X}"
  LINE2="${LINE2} ${SEP} ${CH}${OUT_TOKS} tok/s${X}"
  LINE2="${LINE2} ${SEP} ${CC}⚡${COST_FMT}${X}"
  LINE2="${LINE2} ${SEP} ${TIMER_SEG}"
  LINE2="${LINE2} ${SEP} ${GH}▲${LINES_ADD}${X} ${R}▼${LINES_DEL}${X}"
  LINE2="${LINE2} ${SEP} ${D}${MINS}m${SECS}s${X}"
elif [ "$COLS" -ge 80 ]; then
  # Medium: hide code changes, API duration
  LINE2="${LINE2} ${SEP} ${D}↓${OUT_FMT}${X}"
  LINE2="${LINE2} ${SEP} ${CH}${OUT_TOKS} tok/s${X}"
  LINE2="${LINE2} ${SEP} ${CC}⚡${COST_FMT}${X}"
  LINE2="${LINE2} ${SEP} ${TIMER_SEG}"
elif [ "$COLS" -ge 60 ]; then
  # Narrow: only cost and timer
  LINE2="${LINE2} ${SEP} ${CC}⚡${COST_FMT}${X}"
  LINE2="${LINE2} ${SEP} ${RC}⏳${RESET_DISP}${X}"
fi
# Minimal (<60): only context bar (already set)

printf '%b\n' "$LINE1"
printf '%b\n' "$LINE2"
