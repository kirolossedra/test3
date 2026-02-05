import socket
import sys
import json
import os
from pathlib import Path
from monitor import save_client_sent, save_client_recv

REQUEST_ID = 0

def load_input_file(number_of_requests):
    sample_id = (number_of_requests % 10)
    return Path(f"sample_inputs/sample_input_{sample_id}.txt")

def _counter_path_for(client_ip: str) -> Path:
    p = Path("/tmp/mininet_request_ids")
    p.mkdir(parents=True, exist_ok=True)
    return p / f"{client_ip}.counter"

def _load_req_id(client_ip: str) -> int:
    path = _counter_path_for(client_ip)
    try:
        return int(path.read_text().strip())
    except Exception:
        return 0

def _save_req_id(client_ip: str, value: int) -> None:
    path = _counter_path_for(client_ip)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(str(value))
    os.replace(tmp, path)

def read_graph_file(filepath):
    edges = []
    with open(filepath, 'r') as f:
        for line in f:
            parts = line.strip().split()
            if len(parts) == 2:
                edges.append(parts)
    return edges

def build_graph_dict(edges):
    graph = {}
    for a, b in edges:
        if a not in graph:
            graph[a] = []
        graph[a].append(b)
        if b not in graph:
            graph[b] = []
    return graph

def send_graph_to_lb(graph, lb_ip, lb_port):
    local_vertex_count = len(graph)

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.connect((lb_ip, lb_port))
        client_ip = s.getsockname()[0]

        global REQUEST_ID
        REQUEST_ID = _load_req_id(client_ip)

        # Send one NDJSON request
        s.sendall((json.dumps({"graph": graph, "req_id": REQUEST_ID}) + "\n").encode())

        # Log client-sent half
        save_client_sent(
            client_ip=client_ip,
            request_id=REQUEST_ID,
            client_vertex_count=local_vertex_count
        )

        # Read exactly one response line
        buf = b""
        while b"\n" not in buf:
            chunk = s.recv(4096)
            if not chunk:
                raise RuntimeError("Connection closed before full response")
            buf += chunk
        line, _ = buf.split(b"\n", 1)

        response = json.loads(line.decode())
        vertex_count = response.get("vertex_count")
        received_ip = response.get("client_ip")
        backend_name = response.get("backend")   # b1/b2/b3 after LB mapping
        resp_req_id = response.get("req_id")

        # Optional correctness prints
        ok = True
        if received_ip != client_ip:      ok = False; print("client_ip mismatch")
        if resp_req_id != REQUEST_ID:     ok = False; print("req_id mismatch")
        if vertex_count != local_vertex_count:
            ok = False; print("vertex_count mismatch")
        if backend_name not in {"b1","b2","b3"}:
            ok = False; print("backend name mismatch")
        print(f"[Client] backend={backend_name} req_id={resp_req_id} vertices={vertex_count} correct={ok}")

        # Log client-received half (redundant fields for cross-checks)
        save_client_recv(
            client_ip=client_ip,
            request_id=REQUEST_ID,
            received_request_id=resp_req_id,
            backend_name=backend_name or "",
            received_vertex_count=vertex_count if vertex_count is not None else local_vertex_count
        )

        REQUEST_ID += 1
        _save_req_id(client_ip, REQUEST_ID)

if __name__ == "__main__":
    if len(sys.argv) != 4:
        print("Usage: python3 client.py num_requests lb_ip_address lb_port")
        sys.exit(1)

    number_of_requests = int(sys.argv[1])
    lb_ip = sys.argv[2]
    lb_port = int(sys.argv[3])

    for i in range(number_of_requests):
        edges = read_graph_file(load_input_file(i + 1))
        graph = build_graph_dict(edges)
        send_graph_to_lb(graph, lb_ip=lb_ip, lb_port=lb_port)
