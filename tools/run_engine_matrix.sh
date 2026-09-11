#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/build"

if [[ "${1:-}" == "--build-dir" ]]; then
  if [[ -z "${2:-}" ]]; then
    echo "--build-dir requires a path" >&2
    exit 2
  fi
  BUILD_DIR="$2"
fi

OUT_DIR="$BUILD_DIR/differential_engine_matrix"
RAW_DIR="$OUT_DIR/engine_matrix.raw"
PROBE="$BUILD_DIR/jme_call_probe"
KERNEL_PATH="${JME_TEST_JPL_KERNEL:-$ROOT/data/jpl/de440s.bsp}"

mkdir -p "$OUT_DIR" "$RAW_DIR"

if [[ ! -x "$PROBE" ]]; then
  cmake --build "$BUILD_DIR" --target jme_call_probe >/dev/null
fi

python3 - "$ROOT" "$OUT_DIR" "$RAW_DIR" "$PROBE" "$KERNEL_PATH" <<'PY'
import csv, hashlib, json, math, os, pathlib, re, subprocess, sys

root = pathlib.Path(sys.argv[1])
out_dir = pathlib.Path(sys.argv[2])
raw_dir = pathlib.Path(sys.argv[3])
probe = pathlib.Path(sys.argv[4])
kernel_path = sys.argv[5]

engines = ["JPL", "MOSHIER", "VSOP_ELP_MEEUS"]

text = (root / "include/jme/jme.h").read_text() + "\n" + (root / "include/jme/jme_extended.h").read_text()
funcs = sorted(set(re.findall(r'(?m)^\s*(?:const\s+char\s*\*\s*|char\s*\*\s*|void\s+|double\s+|int\s+)(jme_[a-zA-Z0-9_]+)\s*\(', text)))
constants = sorted(set(re.findall(r'\bJME_[A-Z0-9_]+\b', text)))
if len(funcs) != 204:
    raise SystemExit(f"expected 204 functions, discovered {len(funcs)}")
if len(constants) != 462:
    raise SystemExit(f"expected 462 constants, discovered {len(constants)}")

full_jsonl = out_dir / "engine_matrix.full.jsonl"
summary_csv = out_dir / "engine_matrix.summary.csv"
diff_md = out_dir / "engine_matrix.diff.md"

rows = []
jpl_available = pathlib.Path(kernel_path).is_file()

for fn in funcs:
    rec = {"function_name": fn, "engines": {}}
    for engine in engines:
        fn_dir = raw_dir / fn
        fn_dir.mkdir(parents=True, exist_ok=True)
        raw_file = fn_dir / f"{engine}.json"
        cmd = [str(probe), "--function", fn, "--engine", engine, "--kernel", kernel_path]
        proc = subprocess.run(cmd, cwd=root, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if proc.returncode == 0 and proc.stdout.strip():
            raw_text = proc.stdout.strip()
        else:
            payload = {
                "function": fn,
                "engine": engine,
                "fixture_id": "n/a",
                "category": "infrastructure",
                "status": "INFRASTRUCTURE_ERROR",
                "probe_exit_code": str(proc.returncode),
                "stderr": proc.stderr,
            }
            raw_text = json.dumps(payload, separators=(",", ":"))
        raw_file.write_text(raw_text + "\n")
        data = json.loads(raw_text)
        data["_raw_sha256"] = hashlib.sha256(raw_text.encode("utf-8")).hexdigest()
        rec["engines"][engine] = data
    rows.append(rec)

def relation(a, b):
    sa = a.get("status", "")
    sb = b.get("status", "")
    if sa.startswith("SKIPPED") or sb.startswith("SKIPPED"):
        return "SKIPPED"
    if sa != "OK" and sb != "OK":
        return "ERROR_ALL"
    if sa != "OK" or sb != "OK":
        return "ERROR_ONE_SIDE"
    if a["_raw_sha256"] == b["_raw_sha256"]:
        return "IDENTICAL_RAW"
    return "DIFFERENT_STRUCTURE"

def timing_ns(rec):
    try:
        return rec["timing"]["elapsed_ns"]["unsigned_decimal"]
    except Exception:
        return ""

def timing_ns_int(rec):
    try:
        return int(rec["timing"]["elapsed_ns"]["unsigned_decimal"])
    except Exception:
        return None

with full_jsonl.open("w", encoding="utf-8") as fh:
    for row in rows:
        fh.write(json.dumps(row, separators=(",", ":")) + "\n")

with summary_csv.open("w", newline="", encoding="utf-8") as fh:
    writer = csv.writer(fh)
    writer.writerow([
        "function_name", "category", "fixture_id",
        "jpl_status", "moshier_status", "vsop_elp_meeus_status",
        "jpl_elapsed_ns", "moshier_elapsed_ns", "vsop_elp_meeus_elapsed_ns",
        "jpl_output_sha256", "moshier_output_sha256", "vsop_elp_meeus_output_sha256",
        "jpl_vs_moshier_relation", "jpl_vs_vsop_relation", "moshier_vs_vsop_relation",
        "max_abs_diff_if_numeric", "max_rel_diff_if_numeric", "notes"
    ])
    for row in rows:
        ej = row["engines"]["JPL"]
        em = row["engines"]["MOSHIER"]
        ev = row["engines"]["VSOP_ELP_MEEUS"]
        writer.writerow([
            row["function_name"],
            ej.get("category") or em.get("category") or ev.get("category") or "",
            ej.get("fixture_id") or em.get("fixture_id") or ev.get("fixture_id") or "",
            ej.get("status", ""), em.get("status", ""), ev.get("status", ""),
            timing_ns(ej), timing_ns(em), timing_ns(ev),
            ej["_raw_sha256"], em["_raw_sha256"], ev["_raw_sha256"],
            relation(ej, em), relation(ej, ev), relation(em, ev),
            "", "", ej.get("reason", "") or em.get("reason", "") or ev.get("reason", "")
        ])

identical_all = 0
skipped = 0
errored = 0
slowest = []
per_engine_timing = {engine: {"count": 0, "sum_ns": 0, "max_ns": 0} for engine in engines}
for row in rows:
    statuses = [row["engines"][e].get("status", "") for e in engines]
    if any(s.startswith("SKIPPED") for s in statuses):
        skipped += 1
    elif all(s == "OK" for s in statuses):
        if len({row["engines"][e]["_raw_sha256"] for e in engines}) == 1:
            identical_all += 1
    else:
        errored += 1
    for engine in engines:
        ns = timing_ns_int(row["engines"][engine])
        if ns is not None:
            per_engine_timing[engine]["count"] += 1
            per_engine_timing[engine]["sum_ns"] += ns
            per_engine_timing[engine]["max_ns"] = max(per_engine_timing[engine]["max_ns"], ns)
            slowest.append((ns, row["function_name"], engine, row["engines"][engine].get("status", "")))

slowest.sort(reverse=True)

with diff_md.open("w", encoding="utf-8") as fh:
    fh.write("# Engine Differential Matrix\n\n")
    fh.write(f"- discovered function count: `{len(funcs)}`\n")
    fh.write(f"- tested function count: `{len(rows)}`\n")
    fh.write(f"- skipped function rows: `{skipped}`\n")
    fh.write(f"- rows with one or more engine errors: `{errored}`\n")
    fh.write(f"- identical raw across all three engines: `{identical_all}`\n")
    fh.write(f"- JPL kernel path present: `{'yes' if jpl_available else 'no'}`\n")
    fh.write(f"- full jsonl: `{full_jsonl}`\n")
    fh.write(f"- summary csv: `{summary_csv}`\n")
    fh.write(f"- raw directory: `{raw_dir}`\n")
    fh.write("\n## Per-Engine Timing\n\n")
    for engine in engines:
        stats = per_engine_timing[engine]
        avg_ns = ""
        if stats["count"]:
            avg_ns = str(stats["sum_ns"] // stats["count"])
        fh.write(f"- `{engine}` calls with timing: `{stats['count']}`, total ns: `{stats['sum_ns']}`, avg ns: `{avg_ns}`, max ns: `{stats['max_ns']}`\n")
    fh.write("\n## Slowest Function+Engine Calls\n\n")
    for ns, fn, engine, status in slowest[:20]:
        fh.write(f"- `{fn}` / `{engine}`: `{ns}` ns, status `{status}`\n")
    fh.write("\n## Notes\n\n")
    fh.write("- `ENGINE=JPL` is strict. In this build, JPL-mode success depends on CALCEPH availability plus a real kernel.\n")
    fh.write("- Unadapted functions are still emitted as rows with `SKIPPED_WITH_REASON`.\n")

print(f"discovered function count: {len(funcs)}")
print(f"tested function count: {len(rows)}")
print(f"skipped function count: {skipped}")
print(f"output directory: {out_dir}")
print(f"open summary: {summary_csv}")
PY
