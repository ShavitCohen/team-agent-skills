#!/usr/bin/env python3
"""Read-only machine-capacity gate for a local QA environment.

Measures what the host can actually carry before anything is cloned, built, started
or created. It never mutates a cluster or a container runtime, never touches the
network, and never infers that a Kubernetes context is safe from its name.

The helper imposes no workflow of its own. The caller names what the repository's
documented workflow actually needs:

  --require-command NAME    a CLI that must be installed; repeatable. Naming
                            kubectl is what makes this a Kubernetes run, and only
                            then is a local cluster provider required.
  --min-runtime-cpus 0      pass zero runtime thresholds when the workflow needs no
  --min-runtime-memory-gib 0    container runtime at all.

Thresholds start conservative and may be raised for a repository that documents
larger requirements. A documented requirement is never lowered silently.

Exit codes: 0 proceed, 10 caution, 20 do-not-run.
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import shutil
import subprocess
import sys
import time

SCHEMA_VERSION = 3
GIB = 1024 ** 3

DEFAULT_THRESHOLDS = {
    "min_cpus": 4.0,
    "min_total_memory_gib": 8.0,
    "min_available_memory_gib": 4.0,
    "min_runtime_cpus": 4.0,
    "min_runtime_memory_gib": 6.0,
    "min_disk_gib": 20.0,
    "max_load_per_cpu": 1.5,
}

THRESHOLD_KEYS = tuple(DEFAULT_THRESHOLDS)

CLUSTER_PROVIDERS = ("kind", "k3d", "minikube", "colima", "k3s", "microk8s")


def run(argv, timeout=10):
    """Run a read-only command and return its stdout, or None."""
    try:
        result = subprocess.run(
            argv,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode != 0:
        return None
    return result.stdout.strip()


def logical_cpus():
    try:
        return os.cpu_count() or 0
    except NotImplementedError:
        return 0


def load_average():
    try:
        return os.getloadavg()[0]
    except (OSError, AttributeError):
        return None


def host_memory():
    """Return (total_bytes, available_bytes), either possibly None."""
    total = available = None
    try:
        with open("/proc/meminfo", "r", encoding="utf-8") as handle:
            values = {}
            for line in handle:
                parts = line.split(":")
                if len(parts) == 2:
                    values[parts[0].strip()] = parts[1].strip()
        if "MemTotal" in values:
            total = int(values["MemTotal"].split()[0]) * 1024
        if "MemAvailable" in values:
            available = int(values["MemAvailable"].split()[0]) * 1024
    except (OSError, ValueError, IndexError):
        pass

    if total is None:
        out = run(["sysctl", "-n", "hw.memsize"])
        if out and out.isdigit():
            total = int(out)
    return total, available


def free_disk(path):
    try:
        usage = shutil.disk_usage(path)
        return usage.free
    except OSError:
        return None


def container_runtime():
    """Report an observable container runtime's own CPU and memory allocation."""
    for name in ("docker", "podman"):
        if shutil.which(name) is None:
            continue
        out = run([name, "info", "--format", "{{json .}}"], timeout=15)
        if out is None:
            return {"name": name, "running": False, "cpus": None, "memory_bytes": None}
        try:
            info = json.loads(out)
        except json.JSONDecodeError:
            return {"name": name, "running": True, "cpus": None, "memory_bytes": None}
        host = info.get("host", info)
        cpus = info.get("NCPU", host.get("cpus"))
        memory = info.get("MemTotal", host.get("memTotal"))
        return {
            "name": name,
            "running": True,
            "cpus": cpus if isinstance(cpus, (int, float)) else None,
            "memory_bytes": memory if isinstance(memory, int) else None,
        }
    return {"name": None, "running": False, "cpus": None, "memory_bytes": None}


def kube_context():
    if shutil.which("kubectl") is None:
        return None
    return run(["kubectl", "config", "current-context"]) or None


def gib(value):
    if value is None:
        return None
    return round(value / GIB, 2)


def resolve_thresholds(args):
    """Conservative defaults, overridden only where the caller passed a value."""
    thresholds = dict(DEFAULT_THRESHOLDS)
    for key in THRESHOLD_KEYS:
        supplied = getattr(args, key)
        if supplied is not None:
            thresholds[key] = supplied
    return thresholds


def build_report(args):
    thresholds = resolve_thresholds(args)
    blockers = []
    cautions = []

    required_commands = list(dict.fromkeys(args.require_command or []))
    # Kubernetes is a consequence of what the caller declared, never an assumption
    # this helper makes on a repository's behalf.
    uses_kubernetes = "kubectl" in required_commands
    needs_runtime = (
        thresholds["min_runtime_cpus"] > 0 or thresholds["min_runtime_memory_gib"] > 0
    )

    cpus = logical_cpus()
    load = load_average()
    total_memory, available_memory = host_memory()
    disk_path = args.path if os.path.isdir(args.path) else os.getcwd()
    disk = free_disk(disk_path)
    runtime = container_runtime()
    context = kube_context()

    commands = {name: shutil.which(name) is not None for name in required_commands}
    for name, present in commands.items():
        if not present:
            blockers.append("required command not installed: %s" % name)

    providers = {name: shutil.which(name) is not None for name in CLUSTER_PROVIDERS}
    if uses_kubernetes and not any(providers.values()):
        blockers.append(
            "no local Kubernetes cluster provider found (looked for: %s)"
            % ", ".join(CLUSTER_PROVIDERS)
        )

    if cpus <= 0:
        cautions.append("logical CPU count could not be measured")
    elif cpus < thresholds["min_cpus"]:
        blockers.append("logical CPUs %s below required %s" % (cpus, thresholds["min_cpus"]))

    if load is None:
        cautions.append("load average could not be measured")
    elif cpus > 0 and load / cpus > thresholds["max_load_per_cpu"]:
        cautions.append(
            "load per CPU %.2f exceeds %.2f; the machine is already busy"
            % (load / cpus, thresholds["max_load_per_cpu"])
        )

    if total_memory is None:
        cautions.append("total host memory could not be measured")
    elif total_memory / GIB < thresholds["min_total_memory_gib"]:
        blockers.append(
            "total memory %.1f GiB below required %.1f GiB"
            % (total_memory / GIB, thresholds["min_total_memory_gib"])
        )

    if available_memory is None:
        cautions.append("currently available memory could not be measured")
    elif available_memory / GIB < thresholds["min_available_memory_gib"]:
        blockers.append(
            "available memory %.1f GiB below required %.1f GiB"
            % (available_memory / GIB, thresholds["min_available_memory_gib"])
        )

    if disk is None:
        cautions.append("free disk could not be measured for %s" % disk_path)
    elif disk / GIB < thresholds["min_disk_gib"]:
        blockers.append(
            "free disk %.1f GiB on %s below required %.1f GiB"
            % (disk / GIB, disk_path, thresholds["min_disk_gib"])
        )

    if needs_runtime:
        if not runtime["running"]:
            blockers.append(
                "a running container runtime is required by the requested runtime "
                "thresholds (%s)" % (runtime["name"] or "no runtime installed")
            )
        else:
            if runtime["cpus"] is None:
                cautions.append("container runtime CPU allocation not observable")
            elif runtime["cpus"] < thresholds["min_runtime_cpus"]:
                blockers.append(
                    "container runtime CPUs %s below required %s"
                    % (runtime["cpus"], thresholds["min_runtime_cpus"])
                )
            if runtime["memory_bytes"] is None:
                cautions.append("container runtime memory allocation not observable")
            elif runtime["memory_bytes"] / GIB < thresholds["min_runtime_memory_gib"]:
                blockers.append(
                    "container runtime memory %.1f GiB below required %.1f GiB"
                    % (runtime["memory_bytes"] / GIB, thresholds["min_runtime_memory_gib"])
                )

    if uses_kubernetes and context is None:
        cautions.append("no current Kubernetes context is configured")

    if blockers:
        recommendation = "do-not-run"
    elif cautions:
        recommendation = "caution"
    else:
        recommendation = "proceed"

    return {
        "schema_version": SCHEMA_VERSION,
        "sampled_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "requirements": {
            "declared_commands": required_commands,
            "kubernetes": uses_kubernetes,
            "container_runtime": needs_runtime,
        },
        "platform": {
            "system": platform.system(),
            "release": platform.release(),
            "machine": platform.machine(),
        },
        "thresholds": {key: thresholds[key] for key in THRESHOLD_KEYS},
        "host": {
            "logical_cpus": cpus,
            "load_average_1m": load,
            "total_memory_gib": gib(total_memory),
            "available_memory_gib": gib(available_memory),
            "disk_path": disk_path,
            "free_disk_gib": gib(disk),
        },
        "container_runtime": {
            "name": runtime["name"],
            "running": runtime["running"],
            "cpus": runtime["cpus"],
            "memory_gib": gib(runtime["memory_bytes"]),
        },
        "required_commands": commands,
        "cluster_providers": providers,
        "kubernetes": {
            "current_context": context,
            "current_context_is_local": "unverified",
            "note": "Context locality is never inferred from a name. Prove the endpoint and "
                    "provider are local and single-user before any mutation.",
        },
        "recommendation": recommendation,
        "blockers": blockers,
        "cautions": cautions,
        "read_only": True,
    }


def render_text(report):
    lines = []
    lines.append("recommendation: %s" % report["recommendation"])
    host = report["host"]
    lines.append(
        "cpus=%s load1=%s total_mem=%s GiB avail_mem=%s GiB free_disk=%s GiB (%s)"
        % (
            host["logical_cpus"],
            host["load_average_1m"],
            host["total_memory_gib"],
            host["available_memory_gib"],
            host["free_disk_gib"],
            host["disk_path"],
        )
    )
    runtime = report["container_runtime"]
    lines.append(
        "container runtime: %s running=%s cpus=%s mem=%s GiB (required: %s)"
        % (
            runtime["name"],
            runtime["running"],
            runtime["cpus"],
            runtime["memory_gib"],
            report["requirements"]["container_runtime"],
        )
    )
    lines.append(
        "kubernetes: required=%s context=%s (locality: %s)"
        % (
            report["requirements"]["kubernetes"],
            report["kubernetes"]["current_context"],
            report["kubernetes"]["current_context_is_local"],
        )
    )
    missing = [name for name, present in report["required_commands"].items() if not present]
    lines.append("required commands missing: %s" % (", ".join(missing) if missing else "none"))
    for blocker in report["blockers"]:
        lines.append("BLOCKER: %s" % blocker)
    for caution in report["cautions"]:
        lines.append("CAUTION: %s" % caution)
    return "\n".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Read-only machine-capacity gate for a local QA environment.",
    )
    parser.add_argument("--path", default=os.getcwd(),
                        help="filesystem that will hold source, images, and build output")
    parser.add_argument("--min-cpus", type=float, default=None)
    parser.add_argument("--min-total-memory-gib", type=float, default=None)
    parser.add_argument("--min-available-memory-gib", type=float, default=None)
    parser.add_argument("--min-runtime-cpus", type=float, default=None)
    parser.add_argument("--min-runtime-memory-gib", type=float, default=None)
    parser.add_argument("--min-disk-gib", type=float, default=None)
    parser.add_argument("--max-load-per-cpu", type=float, default=None)
    parser.add_argument("--require-command", action="append", metavar="NAME",
                        help="a CLI the repository's documented workflow needs; repeatable. "
                             "Naming kubectl is what makes this a Kubernetes run")
    parser.add_argument("--format", choices=("text", "json"), default="json")
    args = parser.parse_args(argv)

    report = build_report(args)
    if args.format == "json":
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print(render_text(report))

    return {"proceed": 0, "caution": 10, "do-not-run": 20}[report["recommendation"]]


if __name__ == "__main__":
    sys.exit(main())
