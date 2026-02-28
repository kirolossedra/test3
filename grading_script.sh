#!/bin/bash

echo "[STEP 1] CREATING OUTPUT FILE \"grades.csv\""
echo "INTERFACE_GRADE, NETWORK_GRADE, SINGLE_REQ_GRADE_1, SINGLE_REQ_GRADE_2, SINGLE_REQ_GRADE_3, SINGLE_REQ_GRADE_4, SINGLE_REQ_GRADE_5, SINGLE_REQ_GRADE_6, MULTI_REQ_GRADE_1, MULTI_REQ_GRADE_2, MULTI_REQ_GRADE_3" > grades.csv

echo "[STEP 2] LOADING STUDENT TOPOLOGY"
if ! tmux has-session -t mn 2>/dev/null; then
  tmux new-session -d -s mn 'sudo python3 lab_topology.py'
else
  echo "[INFO] tmux session 'mn' already exists, continuing..."
fi

echo "[INFO] WAITING MININET INITIALIZATION"
sleep 5

echo "[INFO] CLEANING UP PREVIOUS RUN OUTPUT"
rm -f /tmp/student_id.csv
rm -rf /tmp/mininet_request_ids

echo "[STEP 3] RUNNING IP CONFIGURATION CHECK"

# Expected IP map
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

# Collected IP map
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

# Hosts (single interface eth0)
for host in h1 h2 h3 b1 b2 b3; do
    pid=$(pgrep -f "mininet:$host")
    if [ -z "$pid" ]; then
        echo "[ERROR] PID not found for $host"
        continue
    fi
    ip=$(mnexec -a "$pid" ifconfig "${host}-eth0" | grep 'inet ' | awk '{print $2}')
    ips["$host"]="$ip"
    expected="${expected_ips[$host]}"
    ip_check_total=$((ip_check_total+1))
    if [[ "$ip" == "$expected" ]]; then
        ip_check_correct=$((ip_check_correct+1))
        echo "[PASS] $host = $ip (expected $expected)"
    else
        echo "[FAIL] $host = $ip (expected $expected)"
    fi
done

# Load balancer (two interfaces)
lb_pid=$(pgrep -f "mininet:lb")
if [ -n "$lb_pid" ]; then
    for intf in eth0 eth1; do
        ip=$(mnexec -a "$lb_pid" ifconfig "lb-$intf" | grep 'inet ' | awk '{print $2}')
        key="lb_$intf"
        ips["$key"]="$ip"
        expected="${expected_ips[$key]}"
        ip_check_total=$((ip_check_total+1))
        if [[ "$ip" == "$expected" ]]; then
            ip_check_correct=$((ip_check_correct+1))
            echo "[PASS] $key = $ip (expected $expected)"
        else
            echo "[FAIL] $key = $ip (expected $expected)"
        fi
    done
else
    echo "[ERROR] PID not found for lb"
fi

echo "[RESULT] IP CHECK: $ip_check_correct / $ip_check_total"

echo "[STEP 4]  RUNNING CONNECTIVITY CHECK"

clients=("h1" "h2" "h3")
backends=("b1" "b2" "b3")

for source in "${clients[@]}" "${backends[@]}"; do
    pid=$(pgrep -f "mininet:$source")
    if [ -z "$pid" ]; then
        echo "[ERROR] PID not found for $source"
        continue
    fi

    for dest in "${clients[@]}" "${backends[@]}" lb_eth0 lb_eth1; do
        # Skip self-ping
        if [[ "$source" == "$dest" ]]; then
            continue
        fi

        # Skip client → lb_eth1 and backend → lb_eth0
        if [[ " ${clients[@]} " =~ " $source " && "$dest" == "lb_eth1" ]]; then
            continue
        fi
        if [[ " ${backends[@]} " =~ " $source " && "$dest" == "lb_eth0" ]]; then
            continue
        fi

        # If we somehow didn't collect an IP, skip gracefully
        if [[ -z "${ips[$dest]}" || "${ips[$dest]}" == "0.0.0.0" ]]; then
            echo "[WARN] No IP for $dest; skipping $source → $dest"
            continue
        fi

        # Get packet loss %
        result=$(mnexec -a "$pid" ping -c 2 -w 2 "${ips[$dest]}" | grep -oP '\d+(?=% packet loss)')
        [[ -z "$result" ]] && result=100  # fallback if ping fails entirely

        # Determine expected result
        expected=100
        if [[ " ${clients[@]} " =~ " $source " && " ${clients[@]} " =~ " $dest " ]]; then
            expected=0
        elif [[ " ${backends[@]} " =~ " $source " && " ${backends[@]} " =~ " $dest " ]]; then
            expected=0
        elif [[ " ${clients[@]} " =~ " $source " && "$dest" == "lb_eth0" ]]; then
            expected=0
        elif [[ " ${backends[@]} " =~ " $source " && "$dest" == "lb_eth1" ]]; then
            expected=0
        fi

        ((connectivity_total++))
        if [[ "$result" -eq "$expected" ]]; then
            ((connectivity_correct++))
            echo "[PASS] $source → $dest : $result% loss (expected $expected)"
        else
            echo "[FAIL] $source → $dest : $result% loss (expected $expected)"
        fi
    done
done

echo "[RESULT] Connectivity: $connectivity_correct / $connectivity_total tests passed"

for host in b1 b2 b3; do
    pid=$(pgrep -f "mininet:$host")
    if [ -z "$pid" ]; then
        echo "[ERROR] PID not found for $host"
        continue
    fi
    mnexec -a "$pid" bash -lc "cd /root/sample_code && nohup python3 backend_server.py '${ips[$host]}' 6000 > /tmp/$host.log 2>&1 &"
done

lb_pid=$(pgrep -f "mininet:lb")
if [ -z "$lb_pid" ]; then
    echo "[ERROR] PID not found for lb"
else
    mnexec -a "$lb_pid" bash -lc "cd /root/sample_code && nohup python3 load_balancer.py '${ips[lb_eth0]}' 5000 > /tmp/lb.log 2>&1 &"
fi

sleep 3


# Sequential evaluation
echo "[STEP 5] DOING SEQUENTIAL EVALUATION"
declare -a grades=()
for i in {1..2}; do
  for host in h1 h2 h3; do
    pid=$(pgrep -f "mininet:${host}" | head -n1)
    if [ -z "$pid" ]; then
      echo "[ERROR] PID not found for ${host}"
      continue
    fi
    log="/tmp/${host}_seq_${i}.log"

    # run in FOREGROUND (sequential) and redirect output to per-host log
    mnexec -a "$pid" bash -lc "cd /root/sample_code && python3 client.py 100 '${ips[lb_eth0]}' 5000 > '$log' 2>&1"

    # grade THIS run (CSV now only has this host’s rows)
    grade=$(python3 verify_output.py /tmp/student_id.csv | awk '/Score:/ {print $2}' | cut -d/ -f1)
    echo "[INFO] ${host} (seq run ${i}) grade: ${grade}"
    grades+=("$grade")

    # reset CSV for the next host
    rm -f /tmp/student_id.csv
  done
done

# Concurrent evaluation
echo "[STEP 6] DOING CONCURRENT EVALUATION"

pids=()
for host in h1 h2 h3; do
  pid=$(pgrep -f "mininet:${host}" | head -n1)
  if [ -z "$pid" ]; then
    echo "[ERROR] PID not found for ${host}"
    continue
  fi
  log="/tmp/${host}_conc.log"
  # start all three at once, quiet logs
  mnexec -a "$pid" bash -lc "cd /root/sample_code && python3 client.py 100 '${ips[lb_eth0]}' 5000 > '$log' 2>&1" &
  pids+=($!)
done

# wait for all three to finish
wait "${pids[@]}"

# per-host grades: filter CSV by client IP and verify each slice
for host in h1 h2 h3; do
  ip="${ips[$host]}"
  tmp="/tmp/student_id_${host}_conc.csv"
  awk -F, -v ip="$ip" 'NR==1 || $1==ip' /tmp/student_id.csv > "$tmp"
  grade=$(python3 verify_output.py "$tmp" | awk '/Score:/ {print $2}' | cut -d/ -f1)
  echo "[INFO] ${host} (concurrent) grade: ${grade}"
  grades+=("$grade")
  rm -f "$tmp"
done

# clear the combined CSV
rm -f /tmp/student_id.csv

echo "[INFO] Grades: ${grades[*]}"

ip_check_grade=$((${ip_check_correct}/${ip_check_total}))
connectivity_grade=$((${connectivity_correct}/${connectivity_total}))

# Append to CSV
echo "$ip_check_grade, $connectivity_grade, ${grades[0]}, ${grades[1]}, ${grades[2]}, ${grades[3]}, ${grades[4]}, ${grades[5]}, ${grades[6]}, ${grades[7]}, ${grades[8]}" >> grades.csv

echo "[STEP 7] Cleaning up..."
sudo mn -c > /dev/null 2>&1
tmux kill-session -t mn 2>/dev/null || true

echo "[DONE] Grading script finished."

cat grades.csv
