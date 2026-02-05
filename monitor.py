import csv, os, fcntl
from typing import List

csvfile_name = "/tmp/student_id.csv"
HEADER = [
    "CLIENT_IP",
    "REQUEST_ID",
    "CLIENT_VERTEX_COUNT",
    "BACKEND_IP",
    "BACKEND_VERTEX_COUNT",
    "RECEIVED_REQUEST_ID",
    "BACKEND_NAME",
    "RECEIVED_VERTEX_COUNT",
]

def _ensure_parent_dir(path: str) -> None:
    d = os.path.dirname(path)
    if d: os.makedirs(d, exist_ok=True)

def _ensure_csv(path: str, headers: List[str]) -> None:
    _ensure_parent_dir(path)
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        with open(path, "w", newline="") as f:
            csv.writer(f).writerow(headers)

def _lock(f): fcntl.flock(f, fcntl.LOCK_EX)
def _unlock(f): fcntl.flock(f, fcntl.LOCK_UN)

def _norm_row(d: dict) -> dict:
    # Keep only known columns, stringify values, blank if missing
    return {h: ("" if d.get(h) is None else str(d.get(h, ""))) for h in HEADER}

def upsert_row(new_row: dict):
    """Safely insert/update one row; key = (CLIENT_IP, REQUEST_ID)."""
    _ensure_csv(csvfile_name, HEADER)
    new_row = _norm_row(new_row)

    with open(csvfile_name, "r+", newline="") as f:
        _lock(f)
        f.seek(0)
        reader = csv.DictReader(f, fieldnames=HEADER, skipinitialspace=True)
        rows = list(reader)
        # Drop literal header row if present as first row
        if rows and all(rows[0].get(h) == h for h in HEADER):
            rows = rows[1:]

        key = (new_row["CLIENT_IP"], new_row["REQUEST_ID"])
        idx = next((i for i, r in enumerate(rows)
                    if (r.get("CLIENT_IP"), r.get("REQUEST_ID")) == key), None)

        if idx is None:
            rows.append(new_row)
        else:
            # Merge: only overwrite with non-empty values
            for h in HEADER:
                if new_row[h] != "":
                    rows[idx][h] = new_row[h]

        # Rewrite in place under the same lock
        f.seek(0)
        w = csv.DictWriter(f, fieldnames=HEADER)
        w.writeheader()
        w.writerows(rows)
        f.truncate()
        f.flush()
        os.fsync(f.fileno())
        _unlock(f)

# Convenience wrappers
def save_client_sent(*, client_ip: str, request_id: int, client_vertex_count: int) -> None:
    upsert_row({
        "CLIENT_IP": client_ip,
        "REQUEST_ID": str(request_id),
        "CLIENT_VERTEX_COUNT": str(client_vertex_count),
    })

def save_backend_half(*, client_ip: str, request_id: int, backend_ip: str, backend_vertex_count: int) -> None:
    upsert_row({
        "CLIENT_IP": client_ip,
        "REQUEST_ID": str(request_id),
        "BACKEND_IP": backend_ip,
        "BACKEND_VERTEX_COUNT": str(backend_vertex_count),
    })

def save_client_recv(*, client_ip: str, request_id: int, received_request_id: int,
                     backend_name: str, received_vertex_count: int) -> None:
    upsert_row({
        "CLIENT_IP": client_ip,
        "REQUEST_ID": str(request_id),
        "RECEIVED_REQUEST_ID": str(received_request_id),
        "BACKEND_NAME": backend_name,
        "RECEIVED_VERTEX_COUNT": str(received_vertex_count),
    })
