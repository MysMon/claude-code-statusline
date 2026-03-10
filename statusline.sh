#!/bin/bash
# Claude Code Status Line — v4 SF Console HUD
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
X='\033[0m'    # reset

# ── Extract all JSON fields in one jq call ──
eval "$(echo "$input" | jq -r '
  @sh "MODEL=\(.model.display_name)",
  @sh "DIR=\(.workspace.current_dir)",
  @sh "PCT=\(.context_window.used_percentage // 0 | floor)",
  @sh "COST=\(.cost.total_cost_usd // 0)",
  @sh "DURATION_MS=\(.cost.total_api_duration_ms // 0 | floor)",
  @sh "LINES_ADD=\(.cost.total_lines_added // 0)",
  @sh "LINES_DEL=\(.cost.total_lines_removed // 0)",
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

# ── Line 1: ❮ Model ❯ ── dir ──  branch +S ~M ──
LINE1="${C}❮${X} ${CH}${MODEL}${X}"
[ -n "$AGENT" ] && LINE1="${LINE1} ${D}${AGENT}${X}"
[ -n "$VIM_MODE" ] && LINE1="${LINE1} ${D}${VIM_MODE}${X}"
LINE1="${LINE1} ${C}❯${X}"
LINE1="${LINE1} ${D}──${X} ${DIR##*/}"

if [ -n "$BRANCH" ]; then
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

# ── Line 2: ▰▰▰▰▰▱▱▱▱▱ 45% │ ⚡$0.15 │ ▲156 ▼23 │ 3m12s ──
BAR_W=10
FULL=$((PCT * BAR_W / 100))
EMPTY=$((BAR_W - FULL))
BAR=""
for ((i=0; i<FULL; i++)); do BAR="${BAR}▰"; done
for ((i=0; i<EMPTY; i++)); do BAR="${BAR}▱"; done

# Bar color
if [ "$PCT" -ge 90 ]; then BC="$R"
elif [ "$PCT" -ge 70 ]; then BC="$Y"
else BC="$G"; fi

# Cost color
COST_FMT=$(printf '$%.2f' "$COST")
COST_INT=${COST%%.*}
if [ "${COST_INT:-0}" -ge 1 ] 2>/dev/null; then CC="$R"; else CC="$Y"; fi

# Duration
MINS=$((DURATION_MS / 60000))
SECS=$(( (DURATION_MS % 60000) / 1000 ))

SEP="${D}│${X}"

LINE2="${BC}${BAR}${X} ${BC}${PCT}%${X}"
LINE2="${LINE2} ${SEP} ${CC}⚡${COST_FMT}${X}"
LINE2="${LINE2} ${SEP} ${GH}▲${LINES_ADD}${X} ${R}▼${LINES_DEL}${X}"
LINE2="${LINE2} ${SEP} ${D}${MINS}m${SECS}s${X}"

printf '%b\n' "$LINE1"
printf '%b\n' "$LINE2"
