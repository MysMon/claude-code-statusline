#!/bin/bash
# Claude Code Status Line — v5 SF Console HUD
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
  @sh "SESSION_ID=\(.session_id // "")",
  @sh "STYLE=\(.output_style.name // "")",
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

# 5-hour reset timer
RESET_WINDOW_MS=$((5 * 3600 * 1000))
REMAINING_MS=$((RESET_WINDOW_MS - TOTAL_DUR_MS))
[ "$REMAINING_MS" -lt 0 ] && REMAINING_MS=0
REMAINING_S=$((REMAINING_MS / 1000))
RESET_H=$((REMAINING_S / 3600))
RESET_M=$(( (REMAINING_S % 3600) / 60 ))
RESET_DISP=$(printf '%dh%02dm' "$RESET_H" "$RESET_M")

# Reset timer color
if [ "$REMAINING_S" -le 3600 ]; then
  RC="$R"
elif [ "$REMAINING_S" -le 7200 ]; then
  RC="$Y"
else
  RC="$G"
fi

# Session ID (first 8 chars)
SESSION_SHORT=""
[ -n "$SESSION_ID" ] && SESSION_SHORT="${SESSION_ID:0:8}"

# Effort/style badge
EFFORT=""
if [ -n "$STYLE" ] && [ "$STYLE" != "default" ]; then
  EFFORT="$STYLE"
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

# ── Line 1: ❮ Model ❯ [session] [effort] ── dir ──  branch +S ~M ──
LINE1="${C}❮${X} ${CH}${MODEL}${X}"
[ -n "$AGENT" ] && LINE1="${LINE1} ${D}${AGENT}${X}"
[ -n "$VIM_MODE" ] && LINE1="${LINE1} ${D}${VIM_MODE}${X}"
[ -n "$EFFORT" ] && LINE1="${LINE1} ${D}[${EFFORT}]${X}"
LINE1="${LINE1} ${C}❯${X}"

# Session name / ID (show if width allows)
if [ "$COLS" -ge 80 ] && [ -n "$SESSION_SHORT" ]; then
  LINE1="${LINE1} ${D}${SESSION_SHORT}${X}"
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

# ── Line 2: context bar │ tokens │ speed │ cost │ timer │ code │ api ──
BAR_W=10
FULL=$((PCT * BAR_W / 100))
EMPTY=$((BAR_W - FULL))
BAR=""
for ((i=0; i<FULL; i++)); do BAR="${BAR}▰"; done
for ((i=0; i<EMPTY; i++)); do BAR="${BAR}▱"; done

# Always show: context bar
LINE2="${BC}${BAR}${X} ${BC}${PCT}%${X}"

if [ "$COLS" -ge 120 ]; then
  # Full width: everything
  LINE2="${LINE2} ${SEP} ${D}↑${IN_FMT} ↓${OUT_FMT} ⚡${CACHE_FMT}${X}"
  LINE2="${LINE2} ${SEP} ${CH}${OUT_TOKS} tok/s${X}"
  LINE2="${LINE2} ${SEP} ${CC}⚡${COST_FMT}${X}"
  LINE2="${LINE2} ${SEP} ${D}${SESSION_ELAPSED}${X} ${RC}⏳${RESET_DISP}${X}"
  LINE2="${LINE2} ${SEP} ${GH}▲${LINES_ADD}${X} ${R}▼${LINES_DEL}${X}"
  LINE2="${LINE2} ${SEP} ${D}${MINS}m${SECS}s${X}"
elif [ "$COLS" -ge 80 ]; then
  # Medium: hide code changes, API duration
  LINE2="${LINE2} ${SEP} ${D}↓${OUT_FMT}${X}"
  LINE2="${LINE2} ${SEP} ${CH}${OUT_TOKS} tok/s${X}"
  LINE2="${LINE2} ${SEP} ${CC}⚡${COST_FMT}${X}"
  LINE2="${LINE2} ${SEP} ${D}${SESSION_ELAPSED}${X} ${RC}⏳${RESET_DISP}${X}"
elif [ "$COLS" -ge 60 ]; then
  # Narrow: only cost and timer
  LINE2="${LINE2} ${SEP} ${CC}⚡${COST_FMT}${X}"
  LINE2="${LINE2} ${SEP} ${RC}⏳${RESET_DISP}${X}"
fi
# Minimal (<60): only context bar (already set)

printf '%b\n' "$LINE1"
printf '%b\n' "$LINE2"
