#!/bin/bash
# Simple test runner for statusline.sh
# Run: bash test/run_tests.sh

set -euo pipefail
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/statusline.sh"
PASS=0 FAIL=0 TOTAL=0

# ── Helpers ──
strip_ansi() { sed 's/\x1b\[[0-9;]*m//g; s/\x1b\]8;;[^\x07]*\x07//g'; }

run_sl() {
  local json="$1" cols="${2:-120}"
  rm -f /tmp/claude-sl-git /tmp/claude-sl-transcript
  COLUMNS="$cols" HOME="/tmp/claude-sl-test-home" \
    CLAUDE_CONFIG_DIR="/tmp/claude-sl-test-nonexist" \
    bash "$SCRIPT" <<< "$json" 2>/dev/null
}

assert_contains() {
  local haystack="$1" needle="$2" msg="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "  ✓ $msg"
    PASS=$((PASS + 1))
  else
    echo "  ✗ $msg"
    echo "    expected to contain: $needle"
    echo "    got: $haystack"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" msg="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "  ✓ $msg"
    PASS=$((PASS + 1))
  else
    echo "  ✗ $msg"
    echo "    expected NOT to contain: $needle"
    FAIL=$((FAIL + 1))
  fi
}

assert_eq() {
  local actual="$1" expected="$2" msg="$3"
  TOTAL=$((TOTAL + 1))
  if [ "$actual" = "$expected" ]; then
    echo "  ✓ $msg"
    PASS=$((PASS + 1))
  else
    echo "  ✗ $msg"
    echo "    expected: $expected"
    echo "    got: $actual"
    FAIL=$((FAIL + 1))
  fi
}

# ── Base JSON ──
BASE_JSON='{
  "model": {"display_name": "Opus"},
  "workspace": {"current_dir": "/home/user/myproject"},
  "context_window": {
    "used_percentage": 45,
    "total_input_tokens": 125000,
    "total_output_tokens": 38000,
    "current_usage": {"cache_read_input_tokens": 90000}
  },
  "cost": {
    "total_cost_usd": 0.42,
    "total_api_duration_ms": 95000,
    "total_duration_ms": 3600000,
    "total_lines_added": 156,
    "total_lines_removed": 23
  },
  "output_style": {"name": "default"}
}'

# ── Setup ──
rm -f /tmp/claude-sl-git /tmp/claude-sl-transcript
rm -rf /tmp/claude-sl-test-home
mkdir -p /tmp/claude-sl-test-home

# ══════════════════════════════════════════════════════
echo "── Basic output structure ──"
# ══════════════════════════════════════════════════════

result=$(run_sl "$BASE_JSON")
line_count=$(echo "$result" | wc -l)
assert_eq "$line_count" "2" "outputs exactly 2 lines"

line1=$(echo "$result" | head -1 | strip_ansi)
line2=$(echo "$result" | tail -1 | strip_ansi)
assert_contains "$line1" "Opus" "line 1 contains model name"
assert_contains "$line1" "myproject" "line 1 contains directory basename"
assert_contains "$line2" "45%" "line 2 contains context percentage"

# ══════════════════════════════════════════════════════
echo "── Context bar colors ──"
# ══════════════════════════════════════════════════════

json=$(echo "$BASE_JSON" | jq '.context_window.used_percentage = 50')
result=$(run_sl "$json" | tail -1)
assert_contains "$result" $'\033[32m' "green when <70%"

json=$(echo "$BASE_JSON" | jq '.context_window.used_percentage = 75')
result=$(run_sl "$json" | tail -1)
assert_contains "$result" $'\033[33m' "yellow when 70-89%"

json=$(echo "$BASE_JSON" | jq '.context_window.used_percentage = 95')
result=$(run_sl "$json" | tail -1)
assert_contains "$result" $'\033[31m' "red when >=90%"

# ══════════════════════════════════════════════════════
echo "── Token display ──"
# ══════════════════════════════════════════════════════

result=$(run_sl "$BASE_JSON" 120 | tail -1 | strip_ansi)
assert_contains "$result" "125.0K" "formats input tokens in K"
assert_contains "$result" "38.0K" "formats output tokens in K"
assert_contains "$result" "90.0K" "shows cache token count"

json=$(echo "$BASE_JSON" | jq '.context_window.total_input_tokens = 2500000')
result=$(run_sl "$json" 120 | tail -1 | strip_ansi)
assert_contains "$result" "2.5M" "formats tokens in M"

# ══════════════════════════════════════════════════════
echo "── Output speed ──"
# ══════════════════════════════════════════════════════

result=$(run_sl "$BASE_JSON" 120 | tail -1 | strip_ansi)
assert_contains "$result" "400 tok/s" "calculates output tok/s (38000/95=400)"

json=$(echo "$BASE_JSON" | jq '.cost.total_api_duration_ms = 0')
result=$(run_sl "$json" 120 | tail -1 | strip_ansi)
assert_contains "$result" "0 tok/s" "tok/s is 0 when no API duration"

# ══════════════════════════════════════════════════════
echo "── Cost display ──"
# ══════════════════════════════════════════════════════

result=$(run_sl "$BASE_JSON" 120 | tail -1 | strip_ansi)
assert_contains "$result" '$0.42' "shows formatted cost"

json=$(echo "$BASE_JSON" | jq '.cost.total_cost_usd = 2.50')
result=$(run_sl "$json" 120 | tail -1)
assert_contains "$result" $'\033[31m⚡$2.50' "cost red when >= \$1"

# ══════════════════════════════════════════════════════
echo "── Reset timer (fallback) ──"
# ══════════════════════════════════════════════════════

result=$(run_sl "$BASE_JSON" 120 | tail -1 | strip_ansi)
assert_contains "$result" "~4h00m" "fallback timer with ~ prefix (1h elapsed)"
assert_contains "$result" "1h00m" "shows session elapsed time"

json=$(echo "$BASE_JSON" | jq '.cost.total_duration_ms = 20000000')
result=$(run_sl "$json" 120 | tail -1 | strip_ansi)
assert_contains "$result" "~0h00m" "timer capped at 0 when over 5h"

# ══════════════════════════════════════════════════════
echo "── Code changes ──"
# ══════════════════════════════════════════════════════

result=$(run_sl "$BASE_JSON" 120 | tail -1 | strip_ansi)
assert_contains "$result" "▲156" "shows lines added"
assert_contains "$result" "▼23" "shows lines removed"

# ══════════════════════════════════════════════════════
echo "── Width adaptation ──"
# ══════════════════════════════════════════════════════

result=$(run_sl "$BASE_JSON" 140 | tail -1 | strip_ansi)
assert_contains "$result" "tok/s" "full (>=120): shows speed"
assert_contains "$result" "▲" "full (>=120): shows code changes"
assert_contains "$result" '$0.42' "full (>=120): shows cost"

result=$(run_sl "$BASE_JSON" 100 | tail -1 | strip_ansi)
assert_contains "$result" "tok/s" "medium (80-119): shows speed"
assert_not_contains "$result" "▲156" "medium (80-119): hides code changes"
assert_contains "$result" '$0.42' "medium (80-119): shows cost"

result=$(run_sl "$BASE_JSON" 70 | tail -1 | strip_ansi)
assert_contains "$result" '$0.42' "narrow (60-79): shows cost"
assert_not_contains "$result" "tok/s" "narrow (60-79): hides speed"

result=$(run_sl "$BASE_JSON" 50 | tail -1 | strip_ansi)
assert_contains "$result" "45%" "minimal (<60): shows context %"
assert_not_contains "$result" '$0.42' "minimal (<60): hides cost"
assert_not_contains "$result" "tok/s" "minimal (<60): hides speed"

result=$(run_sl "$BASE_JSON" 50 | head -1 | strip_ansi)
assert_not_contains "$result" "myproject" "minimal (<60): hides directory"

# ══════════════════════════════════════════════════════
echo "── Session name from transcript ──"
# ══════════════════════════════════════════════════════

tr_file="/tmp/claude-sl-test-tr-name.jsonl"
printf '%s\n' '{"type":"start"}' '{"type":"custom-title","customTitle":"my-feature"}' > "$tr_file"
json=$(echo "$BASE_JSON" | jq --arg p "$tr_file" '.transcript_path = $p')
result=$(run_sl "$json" 120 | head -1 | strip_ansi)
assert_contains "$result" '"my-feature"' "shows session name from transcript"

printf '%s\n' '{"type":"custom-title","customTitle":"old-name"}' '{"type":"custom-title","customTitle":"new-name"}' > "$tr_file"
json=$(echo "$BASE_JSON" | jq --arg p "$tr_file" '.transcript_path = $p')
result=$(run_sl "$json" 120 | head -1 | strip_ansi)
assert_contains "$result" '"new-name"' "uses most recent session name"

printf '%s\n' '{"type":"custom-title","customTitle":"test"}' > "$tr_file"
json=$(echo "$BASE_JSON" | jq --arg p "$tr_file" '.transcript_path = $p')
result=$(run_sl "$json" 70 | head -1 | strip_ansi)
assert_not_contains "$result" '"test"' "hides session name when width <80"
rm -f "$tr_file"

# ══════════════════════════════════════════════════════
echo "── Effort from transcript ──"
# ══════════════════════════════════════════════════════

tr_file="/tmp/claude-sl-test-tr-effort.jsonl"
printf '%s\n' '{"message":{"content":"<local-command-stdout>Set model to \u001b[1mopus (claude-opus-4-6)\u001b[22m with \u001b[1mhigh\u001b[22m effort</local-command-stdout>"}}' > "$tr_file"
json=$(echo "$BASE_JSON" | jq --arg p "$tr_file" '.transcript_path = $p')
result=$(run_sl "$json" 120 | head -1 | strip_ansi)
assert_contains "$result" "[high]" "extracts high effort from transcript"

printf '%s\n' '{"message":{"content":"<local-command-stdout>Set model to \u001b[1mhaiku\u001b[22m with \u001b[1mlow\u001b[22m effort</local-command-stdout>"}}' > "$tr_file"
json=$(echo "$BASE_JSON" | jq --arg p "$tr_file" '.transcript_path = $p')
result=$(run_sl "$json" 120 | head -1 | strip_ansi)
assert_contains "$result" "[low]" "extracts low effort from transcript"
rm -f "$tr_file"

# Effort from settings.json
mkdir -p /tmp/claude-sl-test-home/.claude
echo '{"effortLevel":"max"}' > /tmp/claude-sl-test-home/.claude/settings.json
rm -f /tmp/claude-sl-git /tmp/claude-sl-transcript
result=$(COLUMNS=120 HOME="/tmp/claude-sl-test-home" \
  CLAUDE_CONFIG_DIR="/tmp/claude-sl-test-home/.claude" \
  bash "$SCRIPT" <<< "$BASE_JSON" 2>/dev/null | head -1 | strip_ansi)
assert_contains "$result" "[max]" "effort fallback to settings.json"
rm -f /tmp/claude-sl-test-home/.claude/settings.json

# No effort when default
result=$(run_sl "$BASE_JSON" 120 | head -1 | strip_ansi)
assert_not_contains "$result" "[default]" "no effort badge when default"

# ══════════════════════════════════════════════════════
echo "── Agent and vim mode ──"
# ══════════════════════════════════════════════════════

json=$(echo "$BASE_JSON" | jq '.agent.name = "security-reviewer"')
result=$(run_sl "$json" 120 | head -1 | strip_ansi)
assert_contains "$result" "security-reviewer" "shows agent name"

json=$(echo "$BASE_JSON" | jq '.vim.mode = "NORMAL"')
result=$(run_sl "$json" 120 | head -1 | strip_ansi)
assert_contains "$result" "NORMAL" "shows vim mode"

# ══════════════════════════════════════════════════════
echo "── Edge cases ──"
# ══════════════════════════════════════════════════════

result=$(run_sl '{"model":{"display_name":"Sonnet"}}' 120)
line_count=$(echo "$result" | wc -l)
assert_eq "$line_count" "2" "handles minimal JSON (2 lines)"
line1=$(echo "$result" | head -1 | strip_ansi)
assert_contains "$line1" "Sonnet" "handles minimal JSON (model shown)"

json=$(echo "$BASE_JSON" | jq '.context_window.total_input_tokens = 0 | .context_window.total_output_tokens = 0')
result=$(run_sl "$json" 120 | tail -1 | strip_ansi)
assert_contains "$result" "0 tok/s" "handles zero tokens"

json=$(echo "$BASE_JSON" | jq '.transcript_path = "/tmp/nonexistent.jsonl"')
result=$(run_sl "$json" 120)
line_count=$(echo "$result" | wc -l)
assert_eq "$line_count" "2" "non-existent transcript does not crash"

# ══════════════════════════════════════════════════════
echo "── API usage cache ──"
# ══════════════════════════════════════════════════════

mkdir -p /tmp/claude-sl-test-home/.cache/claude-sl
cat > /tmp/claude-sl-test-home/.cache/claude-sl/usage.json << 'JSON'
{"five_hour":{"utilization":62.5,"resets_at":"2099-12-31T23:59:59.000Z"}}
JSON
rm -f /tmp/claude-sl-git /tmp/claude-sl-transcript
result=$(COLUMNS=120 HOME="/tmp/claude-sl-test-home" \
  CLAUDE_CONFIG_DIR="/tmp/claude-sl-test-nonexist" \
  bash "$SCRIPT" <<< "$BASE_JSON" 2>/dev/null | tail -1 | strip_ansi)
assert_not_contains "$result" "~" "API mode: no ~ prefix"
# 62.5 rounds to 62 or 63
if [[ "$result" == *"63%"* ]] || [[ "$result" == *"62%"* ]]; then
  TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1)); echo "  ✓ shows API utilization percentage"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1)); echo "  ✗ shows API utilization percentage"
  echo "    got: $result"
fi

# ══════════════════════════════════════════════════════
# ── Cleanup & Summary ──
# ══════════════════════════════════════════════════════

rm -rf /tmp/claude-sl-test-home /tmp/claude-sl-test-tr-*.jsonl
rm -f /tmp/claude-sl-git /tmp/claude-sl-transcript

echo ""
echo "══════════════════════════════════════════════════════"
if [ "$FAIL" -eq 0 ]; then
  echo "  ✓ All $TOTAL tests passed"
else
  echo "  $PASS/$TOTAL passed, $FAIL failed"
fi
echo "══════════════════════════════════════════════════════"

exit "$FAIL"
