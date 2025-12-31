# kill-input-methods-when-idle

## Introduction

There is memory leakage in MacOS Input Methods.

<img width="568" height="186" alt="Screenshot 2025-12-31 at 16 09 06" src="https://github.com/user-attachments/assets/00b85bed-603e-4d69-ab44-97ebf586ff7f" />

So we need something to run periodicially to kill the Input Methods.

### Main References
* https://little-feyfey.medium.com/%E8%A7%A3%E6%B1%BAmac-macbook-%E9%80%B1%E6%9C%9F%E6%80%A7%E5%8D%A1%E9%A0%93%E7%9A%84%E5%95%8F%E9%A1%8C-cause-by-input-method-a215f3b36409

### Other References
* https://medium.com/@mvpdw06/%E8%A7%A3%E6%B1%BA-mbp-%E4%B8%AD%E6%96%87%E8%BC%B8%E5%85%A5%E6%B3%95%E5%8D%A1%E9%A0%93%E5%95%8F%E9%A1%8C-fa7ae45e1df1
* https://www.zhihu.com/question/22382193
* https://www.jianshu.com/p/ec2729d485a8
* https://zhuanlan.zhihu.com/p/625052341?utm_id=0

## Check By Terminal

```bash
ps ax -o pid=,rss=,args= \
| egrep -i '/Input\s*Methods/.*\b(Extensions?|Plugins?)\b' \
| head -n 50 \
| awk '
BEGIN {
    print "============================================================"
    print " Input Methods Processes"
    print "============================================================"
}
{
    pid = $1
    mem = $2
    $1 = $2 = ""
    sub(/^[\x20\t\s]+/, "", $0)

    printf "PID: %-7s  MEM: %7.2f MB\n", pid, mem / 1024
    printf "CMD: %s\n", $0
    print "------------------------------------------------------------"
}'

```

## Usage

### Way 1

#### List
```bash
~/bin/kill_input_methods_when_idle.sh --list
```

#### Force Kill

```bash
~/bin/kill_input_methods_when_idle.sh --force
```

#### Check (Idle)
```bash
~/bin/kill_input_methods_when_idle.sh --check
```


#### Kill (Idle)

```bash
~/bin/kill_input_methods_when_idle.sh
```

### Way 2

#### List

```bash
bash -x ~/bin/kill_input_methods_when_idle.sh --list
```

#### Force Kill

```bash
bash -x ~/bin/kill_input_methods_when_idle.sh --force
```

#### Check (Idle)

```bash
bash -x ~/bin/kill_input_methods_when_idle.sh --check
```

#### Kill (Idle)

```bash
bash -x ~/bin/kill_input_methods_when_idle.sh
```

## How

We’ll do **four stages**:

1. Open Terminal
2. Create the script
3. Create the automatic idle killer
4. Learn how to trigger it manually

Nothing here is permanent or dangerous — you can undo it anytime.

---

### ✅ Stage 1 — Open Terminal

1. Press **⌘ Command + Space**
2. Type **Terminal**
3. Press **Enter**

You should see a window with text like:

```
MacBook-Pro:~ yourname$
```

Leave it open.

---

### ✅ Stage 2 — Create the script

#### Step 2.1 — Create a folder for scripts

Copy **this line**, paste into Terminal, then press **Enter**:

```bash
mkdir -p ~/bin
```

---

#### Step 2.2 — Create the script file

Copy & paste, then press **Enter**:

```bash
nano ~/bin/kill_input_methods_when_idle.sh
```

You are now inside a text editor (nano).

---

#### Step 2.3 — Paste the script

Copy **everything below**:

```bash
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

```

Now **paste it into Terminal**.

---

#### Step 2.4 — Save and exit nano

1. Press **Ctrl + O** (that’s control, not command)
2. Press **Enter**
3. Press **Ctrl + X**

You’re back to the normal Terminal prompt.

---

#### Step 2.5 — Make the script executable

Copy & paste, press **Enter**:

```bash
chmod +x ~/bin/kill_input_methods_when_idle.sh
```

✅ Script created.

---

### ✅ Stage 3 — Set up automatic killing when idle

#### Step 3.1 — Find your home folder path

Copy & paste:

```bash
echo $HOME
```

You will see something like:

```
/Users/john
```

**Remember this value** (or copy it somewhere).

---

#### Step 3.2 — Create the automation file

Copy & paste:

```bash
nano ~/Library/LaunchAgents/com.user.kill-input-methods-when-idle.plist
```

---

#### Step 3.3 — Paste the automation config

Copy **everything below**:

⚠️ Replace `/Users/YOURNAME` with the path you saw earlier
(e.g. `/Users/john`)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.user.kill-input-methods-when-idle</string>

  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>/Users/YOURNAME/bin/kill_input_methods_when_idle.sh</string>
  </array>

  <key>StartInterval</key>
  <integer>300</integer>

  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
```

---

#### Step 3.4 — Save and exit nano

Same as before:

* **Ctrl + O**
* **Enter**
* **Ctrl + X**

---

#### Step 3.5 — Turn it ON

Copy & paste:

```bash
launchctl load ~/Library/LaunchAgents/com.user.kill-input-methods-when-idle.plist
```

Check it loaded:

```bash
launchctl list | grep kill-input-methods
```

If you see a line of text → ✅ it’s working.

---

### ✅ Stage 4 — Manual trigger (your emergency button)

#### Kill input methods immediately

Copy & paste anytime:

```bash
~/bin/kill_input_methods_when_idle.sh --force
```

They will restart automatically when needed.

---

### 🔧 Optional (recommended): Change idle time

The default is **10 minutes**.

To change it:

```bash
nano ~/bin/kill_input_methods_when_idle.sh
```

Find this line:

```bash
IDLE_THRESHOLD=600
```

Change to:

* **300** → 5 minutes
* **900** → 15 minutes
* **1800** → 30 minutes

Save (**Ctrl+O**, **Enter**, **Ctrl+X**), then reload:

```bash
launchctl unload ~/Library/LaunchAgents/com.user.kill-input-methods-when-idle.plist
launchctl load ~/Library/LaunchAgents/com.user.kill-input-methods-when-idle.plist
```

---

### 🧹 How to completely remove everything (if you want)

```bash
launchctl unload ~/Library/LaunchAgents/com.user.kill-input-methods-when-idle.plist
rm ~/Library/LaunchAgents/com.user.kill-input-methods-when-idle.plist
rm ~/bin/kill_input_methods_when_idle.sh
```

---

