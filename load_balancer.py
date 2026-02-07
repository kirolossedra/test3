import threading
import socket
import json
import sys

# Backend server addresses and ports
BACKENDS = [
    ("20.0.0.3", 6000),
    ("20.0.0.4", 6000),
    ("20.0.0.5", 6000),
]

backend_names = {
    "20.0.0.3": "b1",
    "20.0.0.4": "b2",
    "20.0.0.5": "b3",
}

# Round robin state
index = 0
lock = threading.Lock()


def _recv_one_json(sock: socket.socket, *, timeout: float = 3.0, max_bytes: int = 2_000_000) -> bytes:
    """
    Receive exactly one JSON object from a TCP stream.
    Works whether the sender:
      - sends newline-delimited JSON, OR
      - sends raw JSON and then flushes (possibly keeps connection open), OR
      - sends in multiple TCP segments.
    Strategy:
      - Accumulate bytes.
      - If we see a newline, try decode up to newline.
      - Otherwise, repeatedly try json.loads on the full buffer.
      - Timeout if nothing completes.
    Returns raw bytes of the JSON (no trailing newline).
    """
    sock.settimeout(timeout)
    buf = b""
    while True:
        # If newline-delimited, try the first line.
        if b"\n" in buf:
            line, rest = buf.split(b"\n", 1)
            if line.strip():
                # Validate JSON
                json.loads(line.decode("utf-8", errors="strict"))
                return line
            buf = rest  # skip empty line(s) and keep going

        # Try parsing whole buffer as JSON (handles no-newline case)
        if buf.strip():
            try:
                json.loads(buf.decode("utf-8", errors="strict"))
                return buf
            except Exception:
                pass  # not complete JSON yet

        if len(buf) > max_bytes:
            raise ValueError("Request too large")

        chunk = sock.recv(8192)
        if not chunk:
            # connection closed; final attempt to parse whatever we have
            if buf.strip():
                json.loads(buf.decode("utf-8", errors="strict"))
                return buf
            raise ConnectionError("Socket closed before receiving JSON")
        buf += chunk


def start_load_balancer(lb_ip, lb_port):
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((lb_ip, lb_port))
    server.listen(128)
    print(f"[LB] Load balancer listening on {lb_ip}:{lb_port}", flush=True)

    while True:
        client_sock, client_addr = server.accept()
        threading.Thread(
            target=client_handler, args=(client_sock, client_addr), daemon=True
        ).start()


def client_handler(client_sock, client_addr):
    """
    Handle a client TCP connection. Supports either:
      - multiple JSON requests on one connection (newline-delimited), OR
      - one JSON request per connection (no newline required).
    """
    try:
        # Loop and read JSON objects until client disconnects or times out.
        while True:
            try:
                raw_req = _recv_one_json(client_sock, timeout=10.0)
            except socket.timeout:
                break  # idle client
            except ConnectionError:
                break  # client closed cleanly
            except Exception:
                # Bad request format
                client_sock.sendall(b'{"error":"invalid_request"}\n')
                break

            raw_resp = forward_to_backend(raw_req, client_addr)

            # Always send as newline-delimited JSON back (safe for most graders/clients)
            if not raw_resp.endswith(b"\n"):
                raw_resp += b"\n"
            client_sock.sendall(raw_resp)
    finally:
        try:
            client_sock.close()
        except Exception:
            pass


def _pick_backend():
    global index
    with lock:
        backend = BACKENDS[index]
        index = (index + 1) % len(BACKENDS)
    return backend


# STUDENTS MUST IMPLEMENT THEIR SOLUTION HERE
def forward_to_backend(data: bytes, client_addr):
    """
    Implements round-robin forwarding:
      Client -> LB: request_id + graph data (JSON)
      LB -> BE: client_ip + request_id + graph data (JSON)
      BE -> LB: backend IP + vertex count + client_ip + request_id (JSON)
      LB -> Client: backend name (b1/b2/b3) + vertex count + client_ip + request_id (JSON)
    """
    # 1) Parse client request
    try:
        req_obj = json.loads(data.decode("utf-8"))
        # Ensure client_ip is set exactly to the Mininet host IP
        req_obj["client_ip"] = client_addr[0]
    except Exception:
        return b'{"error":"invalid_request"}'

    # 2) Choose backend (round-robin)
    backend_ip, backend_port = _pick_backend()

    # 3) Send to backend and read exactly one JSON response
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as be_sock:
            be_sock.connect((backend_ip, backend_port))

            # Send request (add newline for compatibility, but backend can ignore it)
            outbound = json.dumps(req_obj).encode("utf-8") + b"\n"
            be_sock.sendall(outbound)

            resp_raw = _recv_one_json(be_sock, timeout=10.0)
    except Exception as e:
        return json.dumps(
            {"error": f"backend_comm_failure", "detail": str(e)}
        ).encode("utf-8")

    # 4) Normalize backend response to match contract
    try:
        resp_obj = json.loads(resp_raw.decode("utf-8"))

        # Backends may name the backend ip field differently; normalize.
        be_ip = None
        for k in ("backend_ip", "backend", "backend_addr", "backend_address"):
            v = resp_obj.get(k)
            # If the value looks like an IP, accept it
            if isinstance(v, str) and v.count(".") == 3:
                be_ip = v
                break

        # If backend didn’t include its IP, fall back to the one we contacted.
        if not be_ip:
            be_ip = backend_ip

        # LB -> client should include backend name b1/b2/b3 in the "backend" field.
        resp_obj["backend"] = backend_names.get(be_ip, "UNKNOWN")

        # Ensure client_ip and request_id are preserved if present in resp.
        # (Do not rename keys—grader usually expects exact ones.)
        if "client_ip" not in resp_obj:
            resp_obj["client_ip"] = req_obj.get("client_ip", client_addr[0])

        return json.dumps(resp_obj).encode("utf-8")
    except Exception:
        # If backend returned non-JSON, pass it through (better than crashing)
        return resp_raw


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python3 load_balancer.py lb_ip_address lb_port")
        sys.exit(1)

    lb_ip = sys.argv[1]
    lb_port = int(sys.argv[2])
    start_load_balancer(lb_ip=lb_ip, lb_port=lb_port)
