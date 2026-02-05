import socket, threading, json, sys
from monitor import save_backend_half

REQ_NUM = 0
REQ_LOCK = threading.Lock()
HOST = "0.0.0.0"

def count_vertices(graph_dict):
    return len(graph_dict)

def handle_connection(conn, addr):
    try:
        data = conn.recv(4096)
        if not data:
            return

        request = json.loads(data.decode())
        graph = request.get("graph")
        request_id = request.get("req_id")
        client_ip = request.get("client_ip")

        result = count_vertices(graph)
        payload = {
            "backend": HOST,           # LB will translate to b1/b2/b3 for the client
            "vertex_count": result,
            "client_ip": client_ip,
            "req_id": request_id,
        }

        # Respond first
        conn.sendall(json.dumps(payload).encode())

        # Log backend half (backend_ip + backend_vertex_count)
        with REQ_LOCK:
            global REQ_NUM
            REQ_NUM += 1
        save_backend_half(
            client_ip=client_ip,
            request_id=request_id,
            backend_ip=HOST,
            backend_vertex_count=result
        )

        print(f"[Backend {HOST}] served #{REQ_NUM}", flush=True)

    except Exception as e:
        print(f"[Backend] Error: {e}", flush=True)
        try:
            conn.sendall(b'{"error":"backend_failed"}')
        except Exception:
            pass
    finally:
        conn.close()

def start_backend_server(host, port=6000):
    global HOST
    HOST = host
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((host, port))
    server.listen(128)
    print(f"[Backend] Listening on {host}:{port}", flush=True)

    while True:
        conn, addr = server.accept()
        threading.Thread(target=handle_connection, args=(conn, addr), daemon=True).start()

if __name__ == "__main__":
    if len(sys.argv) != 2 and len(sys.argv) != 3:
        print("Usage: python3 backend_server.py backend_ip [port]")
        sys.exit(1)
    be_ip = sys.argv[1]
    be_port = int(sys.argv[2]) if len(sys.argv) == 3 else 6000
    start_backend_server(host=be_ip, port=be_port)
