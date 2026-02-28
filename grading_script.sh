#!/bin/bash
# grading_script.sh — improved, safer, cleaner output
# Usage examples:
#   sudo ./grading_script.sh
#   SAMPLE_DIR=/home/mininet/test3/sample_code sudo ./grading_script.sh
#   QUIET=1 sudo ./grading_script.sh

set -Eeuo pipefail

# -----------------------------
# Config (override via env vars)
# -----------------------------
SAMPLE_DIR="${SAMPLE_DIR:-/root/sample_code}"
QUIET="${QUIET:-0}"              # 1 = print only WARN/FAIL/ERROR/FATAL + final summary
INIT_WAIT_SEC="${INIT_WAIT_SEC:-5}"
BACKEND_PORT="${BACKEND_PORT:-6000}"
LB_PORT="${LB_PORT:-5000}"
REQ_COUNT="${REQ_COUNT:-100}"

# Output files
GRADES_CSV="${GRADES_CSV:-grades.csv}"

# -----------------------------
# Logging helpers
# -----------------------------
ts() { date +"%Y-%m-%d %H:%M:%S"; }

log() {
  local lvl="$1"; shift
  local msg="$*"

  if [[ "$QUIET" == "1" ]]; then
    case "$lvl" in
      WARN|FAIL|ERROR|FATAL) printf "[%s] [%s] %s\n" "$(ts)" "$lvl" "$msg" ;;
      *) : ;;
    esac
  else
    printf "[%s] [%s] %s\n" "$(ts)" "$lvl" "$msg"
  fi
}

die() { log FATAL "$*"; exit 1; }

step() { log INFO "$*"; }

pass() { log PASS "$*"; }

warn() { log WARN "$*"; }

fail() { log FAIL "$*"; }

# -----------------------------
# Cleanup (always runs)
# -----------------------------
RUN_DIR=""
cleanup() {
  local ec=$?
  if [[ -n "${RUN_DIR:-}" && -d "${RUN_DIR:-}" ]]; then
    # keep logs by default; only remove if user wants
    : # no-op
  fi

  # Clean Mininet + tmux grading session (best-effort)
  sudo mn -c > /dev/null 2>&1 || true
  tmux kill-session -t mn > /dev/null 2>&1 || true

  if [[ $ec -ne 0 ]]; then
    log ERROR "Script exited with code $ec"
    if [[ -n "${RUN_DIR:-}" ]]; then
      log ERROR "Run artifacts kept at: $RUN_DIR"
    fi
  fi
}
trap cleanup EXIT

# -----------------------------
# Small utilities
# -----------------------------
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

find_mn_pid() {
  # Try to return a single PID for mininet:<name>
  local name="$1"
  local p
  p="$(pgrep -f "mininet:${name}" | head -n1 || true)"
  [[ -n "$p" ]] || return 1
  echo "$p"
}

pct() {
  # Print percentage with 2 decimals: pct correct total
  local correct="$1"
  local total="$2"
  if [[ "$total" -eq 0 ]]; then
    echo "0.00"
    return
  fi
  awk -v c="$correct" -v t="$total" 'BEGIN{printf "%.2f", (c/t)*100.0}'
}

safe_grade_from_verify() {
  # Extract grade integer from "Score: X/Y"
  # If missing/parse fails -> 0
  local verify_out="$1"
  local g
  g="$(echo "$verify_out" | awk '/Score:/ {print $2}' | head -n1 | cut -d/ -f1 || true)"
  if [[ -z "${g:-}" ]]; then
    echo "0"
  else
    echo "$g"
  fi
}

# -----------------------------
# Preflight
# -----------------------------
require_cmd tmux
require_cmd pgrep
require_cmd mnexec
require_cmd awk
require_cmd python3
require_cmd ifconfig
require_cmd ping

RUN_DIR="$(mktemp -d /tmp/mn_grade.XXXXXX)"
LOG_DIR="$RUN_DIR/logs"
mkdir -p "$LOG_DIR"

step "Run directory: $RUN_DIR"
step "Using SAMPLE_DIR=$SAMPLE_DIR"
step "QUIET=$QUIET"

# -----------------------------
# STEP 1: Create grades.csv
# -----------------------------
step "STEP 1 — Creating output file \"$GRADES_CSV\""
echo "INTERFACE_GRADE_PCT, NETWORK_GRADE_PCT, SINGLE_REQ_GRADE_1, SINGLE_REQ_GRADE_2, SINGLE_REQ_GRADE_3, SINGLE_REQ_GRADE_4, SINGLE_REQ_GRADE_5, SINGLE_REQ_GRADE_6, MULTI_REQ_GRADE_1, MULTI_REQ_GRADE_2, MULTI_REQ_GRADE_3" > "$GRADES_CSV"

# -----------------------------
# STEP 2: Load topology
# -----------------------------
step "STEP 2 — Loading student topology"
if ! tmux has-session -t mn 2>/dev/null; then
  tmux new-session -d -s mn 'sudo python3 lab_topology.py'
  log INFO "Started tmux session 'mn' running lab_topology.py"
else
  log INFO "tmux session 'mn' already exists; continuing"
fi

step "Waiting $INIT_WAIT_SEC seconds for Mininet initialization"
sleep "$INIT_WAIT_SEC"

# -----------------------------
# STEP 2.5: Cleanup previous artifacts
# -----------------------------
step "Cleaning up previous run output"
rm -f /tmp/student_id.csv || true
rm -rf /tmp/mininet_request_ids || true

# Run-local copies (for debugging)
STUDENT_ID_CSV="/tmp/student_id.csv"

# -----------------------------
# STEP 3: IP configuration check
# -----------------------------
step "STEP 3 — Running IP configuration check"

declare -A expected_ips=(
  [h1]="10.0.0.2"
  [h2]="10.0.0.3"
  [h3]="10.0.0.4"
  [lb_eth0]="10.0.0.9"
  [lb_eth1]="20.0.0.2"
  [b1]="20.0.0.3"
  [b2]="20.0.0.4"
  [b3]="20.0.0.5"
)

declare -A ips=(
  [h1]="0.0.0.0"
  [h2]="0.0.0.0"
  [h3]="0.0.0.0"
  [lb_eth0]="0.0.0.0"
  [lb_eth1]="0.0.0.0"
  [b1]="0.0.0.0"
  [b2]="0.0.0.0"
  [b3]="0.0.0.0"
)

ip_check_total=0
ip_check_correct=0

# Hosts and backends: single interface eth0
for host in h1 h2 h3 b1 b2 b3; do
  if ! pid="$(find_mn_pid "$host")"; then
    fail "PID not found for $host"
    continue
  fi

  ip="$(mnexec -a "$pid" ifconfig "${host}-eth0" | grep 'inet ' | awk '{print $2}' || true)"
  ips["$host"]="$ip"
  expected="${expected_ips[$host]}"

  ((ip_check_total++))
  if [[ "$ip" == "$expected" ]]; then
    ((ip_check_correct++))
    pass "$host = $ip (expected $expected)"
  else
    fail "$host = $ip (expected $expected)"
  fi
done

# Load balancer: two interfaces
if lb_pid="$(find_mn_pid "lb")"; then
  for intf in eth0 eth1; do
    ip="$(mnexec -a "$lb_pid" ifconfig "lb-$intf" | grep 'inet ' | awk '{print $2}' || true)"
    key="lb_$intf"
    ips["$key"]="$ip"
    expected="${expected_ips[$key]}"

    ((ip_check_total++))
    if [[ "$ip" == "$expected" ]]; then
      ((ip_check_correct++))
      pass "$key = $ip (expected $expected)"
    else
      fail "$key = $ip (expected $expected)"
    fi
  done
else
  fail "PID not found for lb"
fi

log INFO "IP CHECK: $ip_check_correct / $ip_check_total ($(pct "$ip_check_correct" "$ip_check_total")%)"

# -----------------------------
# STEP 4: Connectivity check
# -----------------------------
step "STEP 4 — Running connectivity check"

connectivity_total=0
connectivity_correct=0

clients=("h1" "h2" "h3")
backends=("b1" "b2" "b3")

for source in "${clients[@]}" "${backends[@]}"; do
  if ! pid="$(find_mn_pid "$source")"; then
    fail "PID not found for $source"
    continue
  fi

  for dest in "${clients[@]}" "${backends[@]}" lb_eth0 lb_eth1; do
    [[ "$source" == "$dest" ]] && continue

    # Skip client → lb_eth1 and backend → lb_eth0
    if [[ " ${clients[*]} " =~ " $source " && "$dest" == "lb_eth1" ]]; then
      continue
    fi
    if [[ " ${backends[*]} " =~ " $source " && "$dest" == "lb_eth0" ]]; then
      continue
    fi

    # Skip if no IP
    if [[ -z "${ips[$dest]:-}" || "${ips[$dest]}" == "0.0.0.0" ]]; then
      warn "No IP for $dest; skipping $source → $dest"
      continue
    fi

    # Determine expected loss
    expected=100
    if [[ " ${clients[*]} " =~ " $source " && " ${clients[*]} " =~ " $dest " ]]; then
      expected=0
    elif [[ " ${backends[*]} " =~ " $source " && " ${backends[*]} " =~ " $dest " ]]; then
      expected=0
    elif [[ " ${clients[*]} " =~ " $source " && "$dest" == "lb_eth0" ]]; then
      expected=0
    elif [[ " ${backends[*]} " =~ " $source " && "$dest" == "lb_eth1" ]]; then
      expected=0
    fi

    # Measure loss %
    result="$(mnexec -a "$pid" ping -c 2 -w 2 "${ips[$dest]}" 2>/dev/null | grep -oP '\d+(?=% packet loss)' | head -n1 || true)"
    [[ -z "$result" ]] && result=100

    ((connectivity_total++))
    if [[ "$result" -eq "$expected" ]]; then
      ((connectivity_correct++))
      pass "$source → $dest : ${result}% loss (expected $expected)"
    else
      fail "$source → $dest : ${result}% loss (expected $expected)"
    fi
  done
done

log INFO "Connectivity: $connectivity_correct / $connectivity_total ($(pct "$connectivity_correct" "$connectivity_total")%)"

# -----------------------------
# STEP 4.5: Start backend + LB
# -----------------------------
step "Starting backend servers and load balancer"

# Fail fast if sample directory is required and missing
if [[ ! -d "$SAMPLE_DIR" ]]; then
  die "SAMPLE_DIR does not exist: $SAMPLE_DIR
Set it like: SAMPLE_DIR=/home/mininet/test3/sample_code sudo ./grading_script.sh"
fi

# Backends
for host in b1 b2 b3; do
  if ! pid="$(find_mn_pid "$host")"; then
    die "Cannot start backend: PID not found for $host"
  fi

  hostlog="$LOG_DIR/${host}.log"
  # log inside namespace goes to /tmp, but also keep a copy path for convenience
  mnexec -a "$pid" bash -lc "cd '$SAMPLE_DIR' && nohup python3 backend_server.py '${ips[$host]}' '$BACKEND_PORT' > '/tmp/${host}.log' 2>&1 &"
  # fetch a quick tail into run dir if present later
  log INFO "Started backend $host at ${ips[$host]}:$BACKEND_PORT (log: /tmp/${host}.log)"
  echo "Backend $host started at ${ips[$host]}:$BACKEND_PORT" > "$hostlog"
done

# Load balancer
if ! lb_pid="$(find_mn_pid "lb")"; then
  die "Cannot start load balancer: PID not found for lb"
fi
mnexec -a "$lb_pid" bash -lc "cd '$SAMPLE_DIR' && nohup python3 load_balancer.py '${ips[lb_eth0]}' '$LB_PORT' > '/tmp/lb.log' 2>&1 &"
log INFO "Started load balancer at ${ips[lb_eth0]}:$LB_PORT (log: /tmp/lb.log)"

sleep 3

# -----------------------------
# STEP 5: Sequential evaluation
# -----------------------------
step "STEP 5 — Sequential evaluation"
declare -a grades=()

# Ensure clean CSV before evaluation
rm -f "$STUDENT_ID_CSV" || true

for i in {1..2}; do
  for host in h1 h2 h3; do
    if ! pid="$(find_mn_pid "$host")"; then
      fail "PID not found for $host (sequential)"
      grades+=("0")
      continue
    fi

    logpath="$LOG_DIR/${host}_seq_${i}.log"
    # run in FOREGROUND (sequential)
    mnexec -a "$pid" bash -lc "cd '$SAMPLE_DIR' && python3 client.py '$REQ_COUNT' '${ips[lb_eth0]}' '$LB_PORT' > '$logpath' 2>&1" || true

    if [[ ! -f "$STUDENT_ID_CSV" ]]; then
      fail "$host (seq run $i): /tmp/student_id.csv not created"
      grades+=("0")
    else
      verify_out="$(python3 verify_output.py "$STUDENT_ID_CSV" 2>&1 || true)"
      grade="$(safe_grade_from_verify "$verify_out")"
      log INFO "$host (seq run $i) grade: $grade"
      grades+=("$grade")
    fi

    # reset CSV for next host
    rm -f "$STUDENT_ID_CSV" || true
  done
done

# -----------------------------
# STEP 6: Concurrent evaluation
# -----------------------------
step "STEP 6 — Concurrent evaluation"

rm -f "$STUDENT_ID_CSV" || true

pids=()
for host in h1 h2 h3; do
  if ! pid="$(find_mn_pid "$host")"; then
    fail "PID not found for $host (concurrent)"
    continue
  fi
  logpath="$LOG_DIR/${host}_conc.log"
  mnexec -a "$pid" bash -lc "cd '$SAMPLE_DIR' && python3 client.py '$REQ_COUNT' '${ips[lb_eth0]}' '$LB_PORT' > '$logpath' 2>&1" &
  pids+=($!)
done

# wait for all to finish
if [[ "${#pids[@]}" -gt 0 ]]; then
  wait "${pids[@]}" || true
fi

if [[ ! -f "$STUDENT_ID_CSV" ]]; then
  fail "Concurrent: /tmp/student_id.csv not created"
  # Still append three zeros so CSV stays stable
  grades+=("0" "0" "0")
else
  # per-host grade: filter combined CSV by client IP
  for host in h1 h2 h3; do
    ip="${ips[$host]}"
    tmp="$RUN_DIR/student_id_${host}_conc.csv"
    awk -F, -v ip="$ip" 'NR==1 || $1==ip' "$STUDENT_ID_CSV" > "$tmp" || true
    verify_out="$(python3 verify_output.py "$tmp" 2>&1 || true)"
    grade="$(safe_grade_from_verify "$verify_out")"
    log INFO "$host (concurrent) grade: $grade"
    grades+=("$grade")
    rm -f "$tmp" || true
  done
fi

rm -f "$STUDENT_ID_CSV" || true

# -----------------------------
# Final summary + CSV write
# -----------------------------
ip_pct="$(pct "$ip_check_correct" "$ip_check_total")"
conn_pct="$(pct "$connectivity_correct" "$connectivity_total")"

log INFO "Grades array: ${grades[*]:-<empty>}"

# Ensure we have exactly 9 grades (6 sequential + 3 concurrent)
while [[ "${#grades[@]}" -lt 9 ]]; do
  grades+=("0")
done

echo "$ip_pct, $conn_pct, ${grades[0]}, ${grades[1]}, ${grades[2]}, ${grades[3]}, ${grades[4]}, ${grades[5]}, ${grades[6]}, ${grades[7]}, ${grades[8]}" >> "$GRADES_CSV"

step "DONE — Grading finished"
log INFO "Run artifacts: $RUN_DIR"
log INFO "Grades file: $GRADES_CSV"

cat "$GRADES_CSV"
