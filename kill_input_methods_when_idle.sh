#!/bin/bash
set -euo pipefail

# Seconds of inactivity before killing (10 minutes)
IDLE_THRESHOLD=600

# Egrep regex (case-insensitive) applied to: "pid comm args"
# Start broad, then tighten once you see what matches in --list.
TARGET_EGREP_REGEX='\/Input\s*Methods\/.*\b(Extensions?|Plugins?)\b'

get_idle_seconds() {
  ioreg -r -d 1 -k HIDIdleTime -c IOHIDSystem \
  | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}'
}

read_idle_or_zero() {
  local idle
  idle="$(get_idle_seconds 2>/dev/null || true)"
  if [[ -z "${idle:-}" || ! "$idle" =~ ^[0-9]+$ ]]; then
    echo 0
  else
    echo "$idle"
  fi
}

# Print matching processes in a stable format
list_target_procs() {
  # Output: PID<TAB>COMM<TAB>ARGS
  # We intentionally avoid using "grep" on itself by using awk to parse.
  ps ax -o pid=,rss=,comm=,args= \
    | egrep -i "$TARGET_EGREP_REGEX" \
    | awk '
      {
        pid = $1
        rss_kb = $2
        comm = $3
        args = ""
        for (i = 4; i <= NF; i++) {
          if (args == "") args = $i
          else args = args " " $i
        }
        printf "%s\t%.1fMB\t%s\t%s\n", pid, rss_kb / 1024, comm, args
      }
    '
}

kill_targets_by_ps_egrep() {
  local max_attempts=4

  echo "Aggressively terminating processes matching regex: $TARGET_EGREP_REGEX"
  echo "Direct SIGKILL with respawn sweeps (max $max_attempts attempts)"
  echo

  for ((attempt=1; attempt<=max_attempts; attempt++)); do
    local matches
    matches="$(list_target_procs || true)"

    # Remove all whitespace to check if empty
    if [[ -z "${matches//[[:space:]]/}" ]]; then
      echo "Sweep $attempt/$max_attempts: No matching processes found."
      echo "All targets eliminated."
      return 0
    fi

    # Extract just the PIDs for killing and display
    local pids
    pids=$(echo "$matches" | awk -F'\t' '{print $1}' | tr '\n' ' ')

    local count
    count=$(echo "$matches" | wc -l | tr -d ' ')

    echo "Sweep $attempt/$max_attempts: Found $count process(es)"
    echo "  PIDs: $pids"
    echo "  Full details:"
    echo "$matches" | awk -F'\t' '{printf "    PID=%s  RSS=%s  COMM=%s  ARGS=%s\n", $1, $2, $3, $4}'
    echo

    # Kill them all with SIGKILL
    echo "  Sending SIGKILL to PIDs: $pids"
    echo "$matches" | awk -F'\t' '{print $1}' | xargs -n 1 kill -KILL 2>/dev/null || true

    # Short pause to allow potential respawn before next sweep
    (( attempt < max_attempts )) && sleep 1.2
  done

  # Final status check
  echo "Kill sequence complete ($max_attempts sweeps done)."
  local survivors
  survivors="$(list_target_procs || true)"

  if [[ -n "${survivors//[[:space:]]/}" ]]; then
    local survivor_pids
    survivor_pids=$(echo "$survivors" | awk -F'\t' '{print $1}' | tr '\n' ' ')
    echo "Warning: Processes still running after all sweeps."
    echo "  Surviving PIDs: $survivor_pids"
    echo "  Details:"
    echo "$survivors" | awk -F'\t' '{printf "    PID=%s  RSS=%s  COMM=%s  ARGS=%s\n", $1, $2, $3, $4}'
    echo
    echo "Note: These are likely being respawned by the system (e.g., TextInputMenuAgent)."
    echo "They will return when you type or switch input sources."
    echo "For a permanent fix: System Settings → Keyboard → Input Sources → remove/disable the extension."
  else
    echo "Success: No matching processes remain."
  fi
}

case "${1:-}" in
  --list)
    echo "Listing matches (no killing). Regex: $TARGET_EGREP_REGEX"
    matches="$(list_target_procs || true)"
    if [[ -z "${matches//[[:space:]]/}" ]]; then
      echo "No matches."
    else
      echo "$matches" | awk -F'\t' '{printf "  PID=%s  RSS=%s  COMM=%s  ARGS=%s\n", $1, $2, $3, $4}'
    fi
    ;;
  --force)
    echo "Force mode (kill regardless of idle)."
    kill_targets_by_ps_egrep
    ;;
  --check)
    idle="$(read_idle_or_zero)"
    echo "Idle time: ${idle} seconds"
    if (( idle >= IDLE_THRESHOLD )); then
      echo "Status: WOULD kill (idle ≥ ${IDLE_THRESHOLD}s)"
    else
      echo "Status: would NOT kill (idle < ${IDLE_THRESHOLD}s)"
    fi
    ;;
  "")
    idle="$(read_idle_or_zero)"
    if (( idle >= IDLE_THRESHOLD )); then
      echo "Idle is ${idle}s (≥ ${IDLE_THRESHOLD}s): killing targets..."
      kill_targets_by_ps_egrep
    fi
    ;;
  *)
    echo "Unknown option: $1"
    echo "Use: --list, --force, or --check"
    exit 1
    ;;
esac
