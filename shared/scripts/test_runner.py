#!/usr/bin/env python3
# shared-component: test_runner.py v1 sha256=0c30ce55766c19d1ccd3a603cd448f9b01295d391971b4f5aab7d8d1b0249043
"""Run local verification with portable testing policy, evidence, and shared capacity."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import uuid

sys.dont_write_bytecode = True
import semaphore

ENV = {
    "wrapper": "TEAM_SKILLS_TEST_WRAPPER",
    "slots": "TEAM_SKILLS_TEST_SLOTS",
    "reviewer_runs_tests": "TEAM_SKILLS_REVIEWER_RUNS_TESTS",
    "minimal_test_runs": "TEAM_SKILLS_MINIMAL_TEST_RUNS",
}


def policy():
    result = {"schema_version": 1, "opt_in": any(name in os.environ for name in ENV.values()),
              "wrapper": None, "slots": 2, "reviewer_runs_tests": True, "minimal_test_runs": False}
    for key, name in ENV.items():
        if name not in os.environ:
            continue
        value = os.environ[name]
        if key == "wrapper":
            if not value or "\x00" in value or "\n" in value:
                raise ValueError(name + " must name one executable, not a shell command")
            result[key] = value
        elif key == "slots":
            if not value.isascii() or not value.isdecimal() or not 1 <= int(value) <= 256:
                raise ValueError(name + " must be an integer from 1 to 256")
            result[key] = int(value)
        else:
            if value not in ("true", "false"):
                raise ValueError(name + " must be true or false")
            result[key] = value == "true"
    return result


def state_root():
    if os.environ.get("TEAM_SKILLS_STATE_DIR"):
        root = Path(os.environ["TEAM_SKILLS_STATE_DIR"])
    elif os.environ.get("XDG_STATE_HOME"):
        root = Path(os.environ["XDG_STATE_HOME"]) / "team-agent-skills"
    else:
        root = Path.home() / ".local/state/team-agent-skills"
    if not root.is_absolute():
        raise ValueError("state root must be absolute")
    semaphore.private_dir(root)
    return root


def save(path, data):
    path = Path(path)
    if path.is_symlink():
        raise ValueError("refusing symlinked evidence path")
    fd, tmp = tempfile.mkstemp(prefix=".test-result-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(data, stream, sort_keys=True)
            stream.write("\n")
        os.replace(tmp, str(path))
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def git(*args):
    return subprocess.check_output(["git", *args], stderr=subprocess.DEVNULL, text=True).strip()


def revision():
    try:
        return git("rev-parse", "HEAD")
    except (OSError, subprocess.CalledProcessError):
        return None


def require_committed():
    sha = git("rev-parse", "HEAD")
    if git("status", "--porcelain", "--untracked-files=all"):
        raise ValueError("pre-push gate needs a clean committed revision")
    return sha


def status_code(returncode):
    return returncode if returncode >= 0 else 128 - returncode


def execute(receipt, command):
    # The wrapper must invoke this delegate with argv intact. Its private receipt
    # distinguishes wrapper setup failure from an actual command's exit status.
    save(receipt, {"schema_version": 1, "state": "started"})
    try:
        process = subprocess.Popen(command)
    except OSError as error:
        save(receipt, {"schema_version": 1, "state": "environment-gap", "reason": str(error)})
        return 125
    code = status_code(process.wait())
    save(receipt, {"schema_version": 1, "state": "completed", "exit_code": code})
    return code


def stop_group(process):
    if process is None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        pass
    # Also clean up descendants when the wrapper exited before them.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()


def run(args, config):
    result = {"schema_version": 1, "policy": config, "role": args.role, "kind": args.kind,
              "phase": args.phase, "scope": args.scope, "sha": revision(), "cwd": os.getcwd(),
              "command": args.command, "outcome": "environment-gap", "exit_code": 125}
    process = None
    held = False
    root = None
    token = "test-" + uuid.uuid4().hex
    interrupted = [None]

    def on_signal(signum, _frame):
        interrupted[0] = signum

    old = {sig: signal.signal(sig, on_signal) for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
    try:
        if args.role == "qa" and args.kind in ("test", "lint", "e2e"):
            raise ValueError("Manual QA never runs automated suites; use authorized build/install/flow work")
        if args.role == "reviewer" and not config["reviewer_runs_tests"]:
            result.update(outcome="skipped", exit_code=0, reason="Reviewer uses SHA-bound Developer evidence plus CI")
            return result
        if config["minimal_test_runs"] and args.phase == "post-push" and args.role != "qa":
            result.update(outcome="skipped", exit_code=0, reason="unchanged pushed SHA: CI decides; no local rerun")
            return result
        if config["minimal_test_runs"] and args.role == "developer" and args.phase == "round" and args.scope != "affected":
            raise ValueError("minimal rounds require affected checks; the full gate belongs immediately before push")
        if args.phase == "pre-push":
            if args.role != "developer" or args.scope != "full" or not args.result:
                raise ValueError("pre-push requires Developer, full scope, and --result evidence")
            result["sha"] = require_committed()
            repo = Path(git("rev-parse", "--show-toplevel")).resolve()
            if repo == Path(args.result).resolve() or repo in Path(args.result).resolve().parents:
                raise ValueError("keep pre-push evidence outside the worktree")
        if config["opt_in"] or args.heavy:
            root = state_root()
            waiting = False
            while not interrupted[0]:
                answer = semaphore.change(root, "heavy", "local", token, "acquire", config["slots"],
                                          pid=os.getpid())
                if answer["result"] == "acquired":
                    held = True
                    break
                if not waiting:
                    print("test_runner: waiting for shared capacity (not a product finding)", file=sys.stderr)
                    waiting = True
                time.sleep(0.1)
        if interrupted[0]:
            result.update(outcome="interrupted", exit_code=128 + interrupted[0])
            return result
        # Even an external wrapper shares the built-in limit with unwrapped work.
        with tempfile.TemporaryDirectory(prefix="team-test-") as scratch:
            receipt = Path(scratch) / "receipt.json"
            command = [sys.executable, str(Path(__file__).resolve()), "_exec", str(receipt), "--", *args.command]
            if config["wrapper"]:
                command.insert(0, config["wrapper"])
            process = subprocess.Popen(command, start_new_session=True)
            refreshed = 0
            while process.poll() is None:
                if interrupted[0]:
                    break
                if held and time.monotonic() - refreshed >= 5:
                    semaphore.change(root, "heavy", "local", token, "touch", pid=process.pid, process_group=True)
                    refreshed = time.monotonic()
                time.sleep(0.05)
            if interrupted[0]:
                result.update(outcome="interrupted", exit_code=128 + interrupted[0])
            else:
                code = status_code(process.wait())
                data = json.loads(receipt.read_text()) if receipt.exists() else {}
                if data.get("schema_version") == 1 and data.get("state") == "completed" and data["exit_code"] == code:
                    result.update(outcome="passed" if code == 0 else "command-failed", exit_code=code)
                else:
                    result["reason"] = data.get("reason", "wrapper failed before delegate completion or changed its status")
            stop_group(process)
            process = None
        if args.phase == "pre-push" and (require_committed() != result["sha"] or policy() != config):
            raise ValueError("revision or testing policy changed during pre-push gate; rerun on final commit")
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        result.update(outcome="environment-gap", exit_code=125, reason=str(error))
    finally:
        stop_group(process)
        if held:
            try:
                semaphore.change(root, "heavy", "local", token, "release")
            except (OSError, ValueError, KeyError) as error:
                result.update(outcome="environment-gap", exit_code=125, reason="slot release failed: " + str(error))
        for sig, handler in old.items():
            signal.signal(sig, handler)
        if args.result:
            save(args.result, result)
        print("test_runner: " + json.dumps(result, sort_keys=True), file=sys.stderr)
    return result


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "_exec":
        return execute(sys.argv[2], sys.argv[4:])
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    sub.add_parser("config", help="print the resolved policy for child briefs")
    runner = sub.add_parser("run", help="execute argv; wrapper is one executable, never shell-expanded")
    runner.add_argument("--role", required=True, choices=("developer", "reviewer", "qa"))
    runner.add_argument("--kind", required=True, choices=("test", "build", "lint", "e2e", "install", "flow"))
    runner.add_argument("--phase", choices=("round", "pre-push", "post-push"), default="round")
    runner.add_argument("--scope", choices=("affected", "full"), default="affected")
    runner.add_argument("--heavy", action="store_true", help="retain heavy-only capacity without opt-in")
    runner.add_argument("--result", help="write structured evidence to this run's private scratch file")
    runner.add_argument("command", nargs=argparse.REMAINDER)
    check = sub.add_parser("check-gate", help="reject missing, failed, stale, or changed-policy pre-push evidence")
    check.add_argument("--result", required=True)
    args = parser.parse_args()
    try:
        config = policy()
        if args.action == "config":
            print(json.dumps(config, sort_keys=True))
            return 0
        if args.action == "check-gate":
            data = json.loads(Path(args.result).read_text())
            if not (data.get("schema_version") == 1 and data.get("outcome") == "passed" and data.get("phase") == "pre-push"
                    and data.get("scope") == "full" and data.get("role") == "developer"
                    and data.get("sha") == require_committed() and data.get("cwd") == os.getcwd()
                    and data.get("policy") == config):
                raise ValueError("missing, failed or stale full pre-push gate; do not push")
            print("pre-push gate passed for " + data["sha"])
            return 0
        if args.command[:1] == ["--"]:
            args.command.pop(0)
        if not args.command:
            parser.error("a command is required after --")
        return run(args, config)["exit_code"]
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print("test_runner: environment-gap: " + str(error), file=sys.stderr)
        return 125


if __name__ == "__main__":
    sys.exit(main())
