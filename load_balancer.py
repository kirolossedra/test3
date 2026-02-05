import threading, socket, json, sys

# Backend server addresses and ports
BACKENDS = [("20.0.0.3", 6000),
            ("20.0.0.4", 6000),
            ("20.0.0.5", 6000)]

backend_names = {"20.0.0.3": "b1",
                 "20.0.0.4": "b2",
                 "20.0.0.5": "b3"}

# Round robin state
index = 0
lock = threading.Lock()

def start_load_balancer(lb_ip, lb_port):
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((lb_ip, lb_port))
    server.listen(128)
    print(f"[LB] Load balancer listening on {lb_ip}:{lb_port}", flush=True)

    while True:
        client_sock, client_addr = server.accept()
        threading.Thread(target=client_handler, args=(client_sock, client_addr), daemon=True).start()

def client_handler(client_sock, client_addr):
    try:
        buffer = b""
        while True:
            chunk = client_sock.recv(8192)
            if not chunk:
                break  # client closed
            buffer += chunk
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                if not line.strip():
                    continue
                # forward a single request line and get one response
                response = forward_to_backend(line, client_addr)
                # send response as a line too
                if not response.endswith(b"\n"):
                    response += b"\n"
                client_sock.sendall(response)
    finally:
        client_sock.close() 


# STUDENTS MUST IMPLEMENT THEIR SOLUTION HERE
def forward_to_backend(data, client_addr):
    global index

    try:
        request_pre_process = json.loads(data.decode())
        request_pre_process["client_ip"] = client_addr[0]
    except Exception:
        return b'{"error":"invalid_request"}'
    request = json.dumps(request_pre_process).encode()

    with lock:
        backend = BACKENDS[index]
        index = (index + 1) % len(BACKENDS)
        backend_ip, backend_port = backend
    
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as backend_sock:
            backend_sock.connect((backend_ip, backend_port))
            backend_sock.sendall(request)
            resp_raw = backend_sock.recv(4096)
        try:
            response_pre_process = json.loads(resp_raw.decode())
            be_ip = response_pre_process.get("backend")
            be_name = backend_names.get(be_ip, "UNKNOWN")
            response_pre_process["backend"] = be_name
            response = json.dumps(response_pre_process).encode()
        except Exception:
            response = resp_raw

    except Exception as e:
        response = f"[LB] Error communicating with backend {backend_ip}: {e}".encode()

    return response

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python3 load_balancer.py lb_ip_address lb_port")
        sys.exit(1)

    lb_ip = sys.argv[1]
    lb_port = int(sys.argv[2])
    start_load_balancer(lb_ip=lb_ip, lb_port=lb_port)