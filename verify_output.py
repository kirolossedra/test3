#!/usr/bin/env python3
import csv, os, sys

# --- config ---
CSV_PATH = sys.argv[1] if len(sys.argv) > 1 else "/tmp/student_id.csv"
HEADER = [
    "CLIENT_IP","REQUEST_ID","CLIENT_VERTEX_COUNT",
    "BACKEND_IP","BACKEND_VERTEX_COUNT",
    "RECEIVED_REQUEST_ID","BACKEND_NAME","RECEIVED_VERTEX_COUNT"
]
# your expected LB→backend mapping
BACKEND_IP_MAP = {"b1":"20.0.0.3", "b2":"20.0.0.4", "b3":"20.0.0.5"}

def read_rows(path):
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        print(f"[ERROR] CSV not found or empty: {path}")
        sys.exit(2)
    with open(path, "r", newline="") as f:
        # Read using fixed header; drop header line if present
        r = csv.DictReader(f, fieldnames=HEADER, skipinitialspace=True)
        rows = list(r)
        if rows and all(rows[0].get(h) == h for h in HEADER):
            rows = rows[1:]
    return rows

def as_int(x):
    try:
        return int(str(x).strip())
    except Exception:
        return None

def check_row(i, row):
    errs = []
    # 1) REQUEST_ID == RECEIVED_REQUEST_ID
    rid  = as_int(row.get("REQUEST_ID",""))
    rrid = as_int(row.get("RECEIVED_REQUEST_ID",""))
    if rid is None or rrid is None or rid != rrid:
        errs.append("REQUEST_ID≠RECEIVED_REQUEST_ID")

    # 2) CLIENT_VERTEX_COUNT == BACKEND_VERTEX_COUNT == RECEIVED_VERTEX_COUNT
    cv = as_int(row.get("CLIENT_VERTEX_COUNT",""))
    bv = as_int(row.get("BACKEND_VERTEX_COUNT",""))
    rv = as_int(row.get("RECEIVED_VERTEX_COUNT",""))
    if None in (cv, bv, rv) or not (cv == bv == rv):
        errs.append("vertex_counts_not_equal")

    # 3) BACKEND_IP corresponds to BACKEND_NAME
    bname = (row.get("BACKEND_NAME","") or "").strip()
    bip   = (row.get("BACKEND_IP","") or "").strip()
    if bname not in BACKEND_IP_MAP or BACKEND_IP_MAP[bname] != bip:
        errs.append("backend_name_ip_mismatch")

    ok = (len(errs) == 0)
    return ok, errs

def main():
    rows = read_rows(CSV_PATH)
    total = len(rows)
    if total == 0:
        print("[ERROR] No data rows in CSV.")
        sys.exit(2)

    passed = 0
    failures = []
    for i, row in enumerate(rows, start=1):
        ok, errs = check_row(i, row)
        if ok:
            passed += 1
        else:
            failures.append((i, row, errs))

    score = round(100 * passed / total)
    print(f"Score: {score}/100 ({passed}/{total} rows passed)")

    if failures:
        print("\nFailures (up to first 20 shown):")
        for i, (rownum, row, errs) in enumerate(failures[:20], start=1):
            print(f"  - row {rownum}: {', '.join(errs)} | data={row}")

    # exit non-zero if any row failed (useful for CI/grading scripts)
    sys.exit(0 if passed == total else 1)

if __name__ == "__main__":
    main()
