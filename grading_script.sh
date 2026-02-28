#!/bin/bash

# -----------------------------
# Pretty logging (no new deps)
# -----------------------------
ts() { date +"%Y-%m-%d %H:%M:%S"; }
log() { echo "[$(ts)] [$1] $2"; }
INFO() { log "INFO" "$1"; }
PASS() { log "PASS" "$1"; }
FAIL() { log "FAIL" "$1"; }
WARN() { log "WARN" "$1"; }
ERROR() { log "ERROR" "$1"; }

# -----------------------------
# Config
# -----------------------------
INIT_WAIT_SEC="${INIT_WAIT_SEC:-5}"
REQ_COUNT="${REQ_COUNT:-100}"
BACKEND_PORT="${BACKEND_PORT:-6000}"
LB_PORT="${LB_PORT:-5000}"
GRADES_CSV="${GRADES_CSV:-grades.csv}"

# If SAMPLE_DIR not explicitly set, auto-detect it
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SAMPLE_DIR="${SAMPLE_DIR:-}"

detect_sample_dir() {
  # Priority:
  # 1) Explicit SAMPLE_DIR (env)
  # 2) ./sample_code (inside repo)
  # 3) ./sample-code (common variant)
  # 4) /root/sample_code (original assumption)
  # 5) /home/mininet/sample_code (common)
  if [ -n "$SAMPLE_DIR" ] && [ -d "$SAMPLE_DIR" ]; then
    echo "$SAMPLE_DIR"; return 0
  fi
  if [ -d "$SCRIPT_DIR/sample_code" ]; then
    echo "$SCRIPT_DIR/sample_code"; return 0
  fi
  if [ -d "$SCRIPT_DIR/sample-code" ]; then
    echo "$SCRIPT_DIR/sample-code"; return 0
  fi
  if [ -d "/root/sample_code" ]; then
    echo "/root/sample_code"; return 0
  fi
  if [ -d "/home/mininet/sample_code" ]; then
    echo "/home/mininet/sample_code"; return 0
  fi
  echo "" ; return 1
}

SAMPLE_DIR="$(detect_sample_dir || true)"

# -----------------------------
# Helpers
# -----------------------------
find_pid() {
  # returns first matching pid for mininet:<name>
  pgrep -f "mininet:$1" | head -n1
}

grade_from_verify() {
  # Extract integer X from "Score: X/Y"
  # If missing -> 0 (NO BLANK GRADES)
  local file="$1"
  local g
  g="$(python3 verify_output.py "$file" 2>/dev/null | awk '/Score:/ {print $2}' | head -n1 | cut -d/ -f1)"
  if [ -z "$g" ]; then
    echo "0"
  else
    echo "$g"
  fi
}

tail_log() {
  local f="$1"
  if [ -f "$f" ]; then
    echo "----- tail -n 20 $f -----"
    tail -n 20 "$f"
    echo "--------------------------"
  else
    echo "----- $f does not exist -----"
  fi
}

# -----------------------------
# STEP 1: grades.csv
# -----------------------------
INFO "STEP 1] CREATING OUTPUT FILE \"$GRADES_CSV\""
echo "INTERFACE_GRADE, NETWORK_GRADE, SINGLE_REQ_GRADE_1, SINGLE_REQ_GRADE_2, SINGLE_REQ_GRADE_3, SINGLE_REQ_GRADE_4, SINGLE_REQ_GRADE_5, SINGLE_REQ_GRADE_6, MULTI_REQ_GRADE_1, MULTI_REQ_GRADE_2, MULTI_REQ_GRADE_3" > "$GRADES_CSV"

# -----------------------------
# STEP 2: load topology (same)
# -----------------------------
INFO "STEP 2] LOADING STUDENT TOPOLOGY"
if ! tmux has-session -t mn 2>/dev/null; then
  tmux new-session -d -s mn 'sudo python3 lab_topology.py'
else
  INFO "tmux session 'mn' already exists, continuing..."
fi

INFO "WAITING MININET INITIALIZATION ($INIT_WAIT_SEC s)"
sleep "$INIT_WAIT_SEC"

INFO "CLEANING UP PREVIOUS RUN OUTPUT"
rm -f /tmp/student_id.csv
rm -rf /tmp/mininet_request_ids

# -----------------------------
# STEP 3: IP check
# -----------------------------
INFO "STEP 3] RUNNING IP CONFIGURATION CHECK"

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
connectivity_total=0
connectivity_correct=0

for host in h1 h2 h3 b1 b2 b3; do
  pid="$(find_pid "$host")"
  if [ -z "$pid" ]; then
    ERROR "PID not found for $host"
    continue
  fi
  ip="$(mnexec -a "$pid" ifconfig "${host}-eth0" 2>/dev/null | grep 'inet ' | awk '{print $2}')"
  ips["$host"]="$ip"
  expected="${expected_ips[$host]}"
  ip_check_total=$((ip_check_total+1))
  if [ "$ip" = "$expected" ]; then
    ip_check_correct=$((ip_check_correct+1))
    PASS "$host = $ip (expected $expected)"
  else
    FAIL "$host = $ip (expected $expected)"
  fi
done

lb_pid="$(find_pid "lb")"
if [ -n "$lb_pid" ]; then
  for intf in eth0 eth1; do
    ip="$(mnexec -a "$lb_pid" ifconfig "lb-$intf" 2>/dev/null | grep 'inet ' | awk '{print $2}')"
    key="lb_$intf"
    ips["$key"]="$ip"
    expected="${expected_ips[$key]}"
    ip_check_total=$((ip_check_total+1))
    if [ "$ip" = "$expected" ]; then
      ip_check_correct=$((ip_check_correct+1))
      PASS "$key = $ip (expected $expected)"
    else
      FAIL "$key = $ip (expected $expected)"
    fi
  done
else
  ERROR "PID not found for lb"
fi

INFO "IP CHECK: $ip_check_correct / $ip_check_total"

# -----------------------------
# STEP 4: connectivity
# -----------------------------
INFO "STEP 4] RUNNING CONNECTIVITY CHECK"

clients=("h1" "h2" "h3")
backends=("b1" "b2" "b3")

for source in "${clients[@]}" "${backends[@]}"; do
  pid="$(find_pid "$source")"
  if [ -z "$pid" ]; then
    ERROR "PID not found for $source"
    continue
  fi

  for dest in "${clients[@]}" "${backends[@]}" lb_eth0 lb_eth1; do
    [ "$source" = "$dest" ] && continue

    if [[ " ${clients[*]} " =~ " $source " && "$dest" = "lb_eth1" ]]; then
      continue
    fi
    if [[ " ${backends[*]} " =~ " $source " && "$dest" = "lb_eth0" ]]; then
      continue
    fi

    if [ -z "${ips[$dest]}" ] || [ "${ips[$dest]}" = "0.0.0.0" ]; then
      WARN "No IP for $dest; skipping $source → $dest"
      continue
    fi

    result="$(mnexec -a "$pid" ping -c 2 -w 2 "${ips[$dest]}" 2>/dev/null | grep -oP '\d+(?=% packet loss)' | head -n1)"
    [ -z "$result" ] && result=100

    expected=100
    if [[ " ${clients[*]} " =~ " $source " && " ${clients[*]} " =~ " $dest " ]]; then
      expected=0
    elif [[ " ${backends[*]} " =~ " $source " && " ${backends[*]} " =~ " $dest " ]]; then
      expected=0
    elif [[ " ${clients[*]} " =~ " $source " && "$dest" = "lb_eth0" ]]; then
      expected=0
    elif [[ " ${backends[*]} " =~ " $source " && "$dest" = "lb_eth1" ]]; then
      expected=0
    fi

    connectivity_total=$((connectivity_total+1))
    if [ "$result" -eq "$expected" ]; then
      connectivity_correct=$((connectivity_correct+1))
      PASS "$source → $dest : $result% loss (expected $expected)"
    else
      FAIL "$source → $dest : $result% loss (expected $expected)"
    fi
  done
done

INFO "Connectivity: $connectivity_correct / $connectivity_total tests passed"

# -----------------------------
# STEP 4.5: start servers (WORKING)
# -----------------------------
INFO "Using SAMPLE_DIR=${SAMPLE_DIR:-<NOT FOUND>}"

if [ -z "$SAMPLE_DIR" ] || [ ! -d "$SAMPLE_DIR" ]; then
  ERROR "sample_code directory not found. Grades will be 0 because clients/servers can't run."
  ERROR "Fix: set SAMPLE_DIR explicitly, e.g.: SAMPLE_DIR=$SCRIPT_DIR/sample_code sudo ./grading_script.sh"
fi

for host in b1 b2 b3; do
  pid="$(find_pid "$host")"
  if [ -z "$pid" ]; then
    ERROR "PID not found for $host"
    continue
  fi
  mnexec -a "$pid" bash -lc "cd '$SAMPLE_DIR' && nohup python3 backend_server.py '${ips[$host]}' $BACKEND_PORT > /tmp/$host.log 2>&1 &"
done

lb_pid="$(find_pid "lb")"
if [ -z "$lb_pid" ]; then
  ERROR "PID not found for lb"
else
  mnexec -a "$lb_pid" bash -lc "cd '$SAMPLE_DIR' && nohup python3 load_balancer.py '${ips[lb_eth0]}' $LB_PORT > /tmp/lb.log 2>&1 &"
fi

sleep 3

# -----------------------------
# STEP 5: sequential grading (NO BLANKS)
# -----------------------------
INFO "STEP 5] DOING SEQUENTIAL EVALUATION"
declare -a grades=()

for i in {1..2}; do
  for host in h1 h2 h3; do
    pid="$(find_pid "$host")"
    if [ -z "$pid" ]; then
      ERROR "PID not found for ${host}"
      grades+=("0")
      continue
    fi

    logf="/tmp/${host}_seq_${i}.log"
    rm -f /tmp/student_id.csv

    mnexec -a "$pid" bash -lc "cd '$SAMPLE_DIR' && python3 client.py $REQ_COUNT '${ips[lb_eth0]}' $LB_PORT > '$logf' 2>&1"

    if [ ! -f /tmp/student_id.csv ]; then
      ERROR "${host} (seq run ${i}): /tmp/student_id.csv not created → grade=0"
      tail_log "$logf"
      grades+=("0")
    else
      grade="$(grade_from_verify /tmp/student_id.csv)"
      INFO "${host} (seq run ${i}) grade: ${grade}"
      grades+=("$grade")
    fi
  done
done

# -----------------------------
# STEP 6: concurrent grading (NO BLANKS)
# -----------------------------
INFO "STEP 6] DOING CONCURRENT EVALUATION"

rm -f /tmp/student_id.csv

pids=()
for host in h1 h2 h3; do
  pid="$(find_pid "$host")"
  if [ -z "$pid" ]; then
    ERROR "PID not found for ${host}"
    continue
  fi
  logf="/tmp/${host}_conc.log"
  mnexec -a "$pid" bash -lc "cd '$SAMPLE_DIR' && python3 client.py $REQ_COUNT '${ips[lb_eth0]}' $LB_PORT > '$logf' 2>&1" &
  pids+=($!)
done

wait "${pids[@]}"

if [ ! -f /tmp/student_id.csv ]; then
  ERROR "Concurrent: /tmp/student_id.csv not created → all concurrent grades=0"
  for host in h1 h2 h3; do
    tail_log "/tmp/${host}_conc.log"
  done
  grades+=("0" "0" "0")
else
  for host in h1 h2 h3; do
    ip="${ips[$host]}"
    tmp="/tmp/student_id_${host}_conc.csv"
    awk -F, -v ip="$ip" 'NR==1 || $1==ip' /tmp/student_id.csv > "$tmp"
    grade="$(grade_from_verify "$tmp")"
    INFO "${host} (concurrent) grade: ${grade}"
    grades+=("$grade")
    rm -f "$tmp"
  done
fi

rm -f /tmp/student_id.csv

INFO "Grades: ${grades[*]}"

# Same binary grading as original
ip_check_grade=$((${ip_check_correct}/${ip_check_total}))
connectivity_grade=$((${connectivity_correct}/${connectivity_total}))

# Ensure exactly 9 grade slots (fill missing with 0)
while [ "${#grades[@]}" -lt 9 ]; do
  grades+=("0")
done

echo "$ip_check_grade, $connectivity_grade, ${grades[0]}, ${grades[1]}, ${grades[2]}, ${grades[3]}, ${grades[4]}, ${grades[5]}, ${grades[6]}, ${grades[7]}, ${grades[8]}" >> "$GRADES_CSV"

INFO "STEP 7] Cleaning up..."
sudo mn -c > /dev/null 2>&1
tmux kill-session -t mn 2>/dev/null || true

INFO "[DONE] Grading script finished."
cat "$GRADES_CSV"
