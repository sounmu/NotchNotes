#!/usr/bin/env python3
"""Sequential GUI benchmarks; includes newly spawned WebKit XPC processes.

Do not launch other WebKit apps during a run. XPC services are launchd children,
so PPID alone cannot identify them. We retain the exact observed process set.
"""
import argparse
import ctypes
import json
from pathlib import Path
import platform
import statistics
import subprocess
import time

ROOT = Path(__file__).resolve().parent


class Usage(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [
        (name, ctypes.c_uint64) for name in (
            "user", "system", "wakeups", "interrupts", "pageins", "wired",
            "resident", "footprint", "start", "exit")]


libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
libproc.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
libproc.proc_pid_rusage.restype = ctypes.c_int


def processes():
    rows = subprocess.check_output(["ps", "-axo", "pid=,ppid=,comm="], text=True)
    return {int(pid): {"ppid": int(ppid), "command": command}
            for line in rows.splitlines() if len(parts := line.strip().split(None, 2)) == 3
            for pid, ppid, command in [parts]}


def usage(pid):
    info = Usage()
    if libproc.proc_pid_rusage(pid, 0, ctypes.byref(info)) != 0:
        return None
    return {"footprintMiB": info.footprint / 2**20, "rssMiB": info.resident / 2**20,
            "cpuSeconds": (info.user + info.system) / 1e9}


def run(engine, size, iteration, output, capture):
    name = f"{engine}-{size}-{iteration}"
    report = output / f"{name}.json"
    report.unlink(missing_ok=True)
    baseline = processes()
    binary = ROOT / "apps" / f"Editor Lab {engine}.app" / "Contents/MacOS/EditorComparison"
    started = time.monotonic()
    samples, observed = [], {}
    with (output / f"{name}.log").open("w") as log:
        process = subprocess.Popen([str(binary), "--engine", engine, "--size", str(size),
                                    "--report", str(report), "--automated"] + (["--capture"] if capture else []), stdout=log, stderr=log)
        failure = None
        try:
            while process.poll() is None:
                if time.monotonic() - started > 90:
                    failure = "Timed out after 90s"
                    break
                current = processes()
                selected = {process.pid}
                for pid, item in current.items():
                    if item["ppid"] == process.pid or (
                            engine == "crepe" and pid not in baseline and "com.apple.WebKit." in item["command"]):
                        selected.add(pid)
                values = {}
                for pid in selected:
                    info = usage(pid)
                    if info is not None:
                        values[str(pid)] = info
                        observed[str(pid)] = current.get(pid, {})
                try:
                    state = json.loads(report.read_text())
                except (FileNotFoundError, json.JSONDecodeError):
                    state = {}
                samples.append({"time": time.monotonic(), "phase": state.get("phase"), "processes": values})
                time.sleep(0.25)
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=10)
    result = json.loads(report.read_text()) if report.exists() else {}
    if failure:
        result["error"] = failure
    result["exitCode"] = process.returncode
    result["processes"] = observed
    idle = [sample for sample in samples if sample["phase"] == "idle"]
    if idle:
        result["idleFootprintMiB"] = statistics.median(
            sum(p["footprintMiB"] for p in s["processes"].values()) for s in idle)
        result["idleRSSMiB"] = statistics.median(
            sum(p["rssMiB"] for p in s["processes"].values()) for s in idle)
        if len(idle) > 1:
            first, last = idle[0], idle[-1]
            common = first["processes"].keys() & last["processes"].keys()
            cpu = sum(last["processes"][pid]["cpuSeconds"] - first["processes"][pid]["cpuSeconds"] for pid in common)
            result["idleCPUPercentOneCore"] = 100 * cpu / (last["time"] - first["time"])
    result["samples"] = samples
    checks = [result.get(key) is True for key in ["bindingSaved", "tabRoundTrip", "diskRoundTrip", "otherNotePreserved"]]
    checks.extend(result.get("smoke", {}).get(key) is True for key in ["undo", "redo", "unicode"])
    if engine == "crepe":
        checks.extend(result.get("smoke", {}).get(key) is True for key in ["checked", "unchecked"])
        if not any("WebContent" in p.get("command", "") for p in observed.values()):
            checks.append(False)
    result["checksPassed"] = result.get("phase") == "done" and all(checks) and process.returncode == 0
    (output / f"{name}-resources.json").write_text(json.dumps(result, indent=2))
    print(f"{name}: ready={result.get('firstReadyMS', -1):.0f}ms "
          f"footprint={result.get('idleFootprintMiB', -1):.1f}MiB "
          f"idleCPU={result.get('idleCPUPercentOneCore', -1):.2f}% checks={result['checksPassed']}", flush=True)
    # Let this run's XPC services leave before taking the next baseline.
    time.sleep(2)
    return {k: v for k, v in result.items() if k != "samples"}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repetitions", type=int, default=3)
    parser.add_argument("--sizes", type=int, nargs="+", default=[1000, 10000, 50000])
    parser.add_argument("--capture", action="store_true")
    parser.add_argument("--output", type=Path, default=ROOT / "results" / time.strftime("%Y%m%d-%H%M%S"))
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    results = []
    for size in args.sizes:
        for iteration in range(args.repetitions):
            # Alternate order to reduce systematic warm-cache bias.
            for engine in (["native", "crepe"] if iteration % 2 == 0 else ["crepe", "native"]):
                results.append(run(engine, size, iteration, args.output, args.capture))
    summary = {"platform": platform.platform(), "machine": platform.machine(), "results": results,
               "method": "Release; visible 680x540 window; 3s settle + 6s idle; fresh process/warm OS caches; proc_pid_rusage footprint + CPU; WebKit attribution by new XPC PIDs"}
    (args.output / "summary.json").write_text(json.dumps(summary, indent=2))
    print(args.output / "summary.json")
    if not all(row["checksPassed"] for row in results):
        raise SystemExit("One or more behavioral checks failed; see JSON and logs.")


if __name__ == "__main__":
    main()
