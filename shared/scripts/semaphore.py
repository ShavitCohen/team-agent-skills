#!/usr/bin/env python3
# shared-component: semaphore.py v1 sha256=9291a4175057c94026b3ad02390e19b496c970d4ea0f533608290209a42a5436
"""Atomic, portable POSIX semaphore backing run_lock.sh's sem-* commands."""
import argparse
import contextlib
import fcntl
import json
import os
from pathlib import Path
import re
import stat
import sys
import time


def component(value):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", value) or ".." in value:
        raise ValueError("invalid semaphore component")
    return value


def private_dir(path):
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    mode = path.lstat().st_mode
    if not stat.S_ISDIR(mode) or mode & 0o022:
        raise ValueError("unsafe semaphore directory: " + str(path))


def read_lease(path):
    if path.is_symlink():
        raise ValueError("symlinked semaphore lease")
    with path.open() as stream:
        data = json.load(stream)
    if data.get("schema_version") != 1:
        raise ValueError("unknown semaphore schema_version; preserved")
    return data


def write_lease(path, data):
    tmp = path.with_name("lease.tmp." + str(os.getpid()))
    fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(data, stream)
            stream.write("\n")
        os.replace(str(tmp), str(path))
    finally:
        if tmp.exists():
            tmp.unlink()


def live(data):
    if time.time() - data["heartbeat"] <= data["ttl"]:
        return True
    # A supervisor that was killed must not free capacity while its child lives.
    if data.get("pid"):
        try:
            if data.get("process_group"):
                os.killpg(data["pid"], 0)
            else:
                os.kill(data["pid"], 0)
            return True
        except ProcessLookupError:
            pass
        except PermissionError:
            return True
    return False


@contextlib.contextmanager
def locked(root, kind, key):
    private_dir(root)
    for path in (root / "locks", root / "locks" / ("sem-" + component(kind))):
        private_dir(path)
    base = path / component(key)
    private_dir(base)
    fd = os.open(str(base / ".guard"), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        if os.fstat(fd).st_mode & 0o022:
            raise ValueError("unsafe semaphore guard")
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield base
    finally:
        os.close(fd)


def change(root, kind, key, run_id, operation, capacity=2, ttl=900, pid=None, process_group=False):
    component(run_id)
    with locked(root, kind, key) as base:
        leases = []
        for directory in sorted(base.glob("slot-*.lock")):
            private_dir(directory)
            path = directory / "lease.json"
            # An incomplete or corrupt record is protected, never stolen.
            data = read_lease(path)
            leases.append((directory, path, data))
        owned = [(d, p, v) for d, p, v in leases if v["run_id"] == run_id]
        if operation == "release":
            for directory, path, _ in owned:
                path.unlink()
                directory.rmdir()
            return {"result": "released", "slots_released": len(owned)}
        if operation == "touch":
            for _, path, data in owned:
                data["heartbeat"] = int(time.time())
                if pid is not None:
                    data.update(pid=pid, process_group=process_group)
                write_lease(path, data)
            if not owned:
                raise ValueError("semaphore ownership lost")
            return {"result": "touched"}
        occupied = []
        for directory, path, data in leases:
            if live(data):
                if data.get("capacity", 2) != capacity:
                    raise ValueError("active semaphore capacity differs; use one machine-wide setting")
                occupied.append(directory)
            else:
                path.unlink()
                directory.rmdir()
        # Resume the same holder before considering an earlier free slot.
        for directory, path, data in owned:
            if directory in occupied:
                data["heartbeat"] = int(time.time())
                write_lease(path, data)
                slot = int(directory.name[5:-5])
                return {"result": "acquired", "slot": slot, "capacity": capacity, "lock": str(directory)}
        for slot in range(1, capacity + 1):
            directory = base / ("slot-%s.lock" % slot)
            if directory in occupied and not any(d == directory for d, _, _ in owned):
                continue
            private_dir(directory)
            write_lease(directory / "lease.json", {
                "schema_version": 1, "kind": "lease", "skill": "sem-" + kind,
                "key": key, "run_id": run_id, "pid": pid, "process_group": process_group,
                "acquired_at": int(time.time()), "heartbeat": int(time.time()),
                "ttl": ttl, "capacity": capacity,
            })
            return {"result": "acquired", "slot": slot, "capacity": capacity, "lock": str(directory)}
        return {"result": "exhausted", "capacity": capacity}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("acquire", "release", "touch"))
    parser.add_argument("root", type=Path)
    parser.add_argument("kind", type=component)
    parser.add_argument("key", type=component)
    parser.add_argument("--run-id", required=True, type=component)
    parser.add_argument("--capacity", type=int, default=2)
    parser.add_argument("--ttl", type=int, default=900)
    parser.add_argument("--wait", type=int, default=os.environ.get("TEAM_SKILLS_SEM_WAIT", "3600"))
    parser.add_argument("--pid", type=int)
    parser.add_argument("--process-group", action="store_true")
    args = parser.parse_args()
    if not args.root.is_absolute() or not 1 <= args.capacity <= 256 or args.ttl < 60 or args.wait < 0 or (args.pid is not None and args.pid < 1):
        parser.error("require absolute root, capacity 1..256, TTL >=60, wait >=0, PID >0")
    started = time.monotonic()
    try:
        while True:
            result = change(args.root, args.kind, args.key, args.run_id, args.operation,
                            args.capacity, args.ttl, args.pid, args.process_group)
            if result["result"] != "exhausted" or time.monotonic() - started >= args.wait:
                result.update(semaphore=args.kind, key=args.key, run_id=args.run_id)
                result["waited"] = int(time.monotonic() - started)
                print(json.dumps(result, separators=(",", ":")))
                return 3 if result["result"] == "exhausted" else 0
            time.sleep(0.1)
    except (OSError, ValueError, KeyError) as error:
        print("semaphore: " + str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
