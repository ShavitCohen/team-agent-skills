#!/usr/bin/env python3
# shared-component: testing-policy.py v1 sha256=1b980638645c86125bc25501a12c65c21680fd1b8e04f4296a53f711c584140d
"""Offline behavioral checks for portable verification policy and command supervision."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

PACKAGE = Path(__file__).resolve().parents[1]
RUNNER = PACKAGE / "scripts/test_runner.py"
CONTRACTS_ONLY = "--contracts-only" in sys.argv
if CONTRACTS_ONLY:
    sys.argv.remove("--contracts-only")


class Contracts(unittest.TestCase):
    def test_self_contained_contract(self):
        for name in ("scripts/test_runner.py", "scripts/semaphore.py", "references/policy/testing.md",
                     "schemas/testing-policy-v1.json"):
            self.assertTrue((PACKAGE / name).is_file(), name)
        skill = (PACKAGE / "SKILL.md").read_text()
        self.assertIn("references/policy/testing.md", skill)
        self.assertIn("scripts/test_runner.py config", skill)
        policy = (PACKAGE / "references/policy/testing.md").read_text()
        for phrase in ("zero test/build/lint", "full applicable", "Manual QA never runs",
                       "Developer evidence @<sha> + CI", "exact head SHA", "child environment"):
            self.assertIn(phrase, policy.replace("\n", " "))
        schema = json.loads((PACKAGE / "schemas/testing-policy-v1.json").read_text())
        self.assertEqual(schema["properties"]["reviewer_runs_tests"], {"type": "boolean"})
        # Child templates must actually mention the policy, not rely on an implicit inheritance.
        for name in ("references/worker-brief.md", "references/reviewer-brief.md", "references/stage-briefs.md"):
            file = PACKAGE / name
            if file.exists():
                self.assertIn("testing policy", file.read_text().lower(), name)


@unittest.skipIf(CONTRACTS_ONLY, "behavior exercised by pr-review's validator")
class Runner(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="testing-policy-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("TEAM_SKILLS_")}
        self.env["TEAM_SKILLS_STATE_DIR"] = str(self.root / "state")
        self.env["PYTHONDONTWRITEBYTECODE"] = "1"
        self.evidence = self.root / "result.json"
        self.cwd = self.root
        self.command = [sys.executable, "-c", "pass"]

    def args(self, role="developer", kind="test", phase="round", scope="affected", command=None, result=None):
        return [str(RUNNER), "run", "--role", role, "--kind", kind, "--phase", phase,
                "--scope", scope, "--result", str(result or self.evidence), "--", *(command or self.command)]

    def run_command(self, **kwargs):
        proc = subprocess.run(self.args(**kwargs), env=self.env, cwd=self.cwd, capture_output=True, text=True)
        data = json.loads(self.evidence.read_text()) if self.evidence.exists() else {}
        return proc, data

    def slots(self):
        return list((self.root / "state/locks/sem-heavy/local").glob("slot-*.lock"))

    def wait_for(self, check, process=None):
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            if check():
                return
            if process is not None and process.poll() is not None:
                self.fail("child exited before checkpoint")
            time.sleep(0.03)
        self.fail("checkpoint timed out")

    def wrapper(self, text):
        path = self.root / "wrapper with spaces"
        path.write_text("#!/usr/bin/env bash\n" + text + "\n")
        path.chmod(0o755)
        self.env["TEAM_SKILLS_TEST_WRAPPER"] = str(path)

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.cwd, env=self.env, stderr=subprocess.DEVNULL, text=True).strip()

    def repository(self):
        self.cwd = self.root / "repo"
        self.cwd.mkdir()
        self.git("init", "-q")
        self.git("config", "user.name", "Fixture Developer")
        self.git("config", "user.email", "fixture@example.invalid")
        (self.cwd / "file").write_text("base")
        self.git("add", "file")
        self.git("commit", "-qm", "fixture")

    def test_defaults_and_argv(self):
        output = self.root / "argv.json"
        args = ["a b", "", "$(false)", "semi;colon", "quotes'\"", "line\nbreak"]
        command = [sys.executable, "-c", "import json,sys;open(sys.argv[1],'w').write(json.dumps(sys.argv[2:]))", str(output), *args]
        proc, data = self.run_command(command=command)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(json.loads(output.read_text()), args)
        self.assertFalse(data["policy"]["opt_in"])
        self.assertFalse((self.root / "state").exists())
        self.assertEqual(data["policy"]["slots"], 2)
        self.assertTrue(data["policy"]["reviewer_runs_tests"])

    def test_explicit_false_is_opt_in_and_child_inherits(self):
        self.env["TEAM_SKILLS_MINIMAL_TEST_RUNS"] = "false"
        output = self.root / "child.json"
        command = [sys.executable, "-c", "import subprocess,sys;open(sys.argv[1],'w').write(subprocess.check_output([sys.argv[2],'config'],text=True))", str(output), str(RUNNER)]
        proc, data = self.run_command(command=command)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(json.loads(output.read_text()), data["policy"])
        self.assertTrue(data["policy"]["opt_in"])
        self.assertFalse(self.slots())

    def test_invalid_settings_never_execute(self):
        for key, value in (("TEST_SLOTS", "0"), ("TEST_SLOTS", "2.5"), ("TEST_SLOTS", "257"),
                           ("REVIEWER_RUNS_TESTS", "False"), ("MINIMAL_TEST_RUNS", ""), ("TEST_WRAPPER", "")):
            env = dict(self.env, **{"TEAM_SKILLS_" + key: value})
            proc = subprocess.run(self.args(command=["definitely-not-a-command"]), env=env, capture_output=True)
            self.assertEqual(proc.returncode, 125)
            self.assertIn(b"environment-gap", proc.stderr)

    def test_wrapper_preserves_argv(self):
        self.wrapper('printf wrapper > "$TEAM_SKILLS_STATE_DIR/../wrapped"\nexec "$@"')
        proc, data = self.run_command(command=[sys.executable, "-c", "import sys;assert sys.argv[1:] == ['a b', '', '$x']", "a b", "", "$x"])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(data["outcome"], "passed")
        self.assertTrue((self.root / "wrapped").exists())
        self.assertFalse(self.slots())

    def test_wrapper_startup_failure_is_environment_gap_even_zero(self):
        for code in (0, 7):
            self.wrapper("exit " + str(code))
            proc, data = self.run_command()
            self.assertEqual(proc.returncode, 125)
            self.assertEqual(data["outcome"], "environment-gap")
            self.assertFalse(self.slots())
        self.env["TEAM_SKILLS_TEST_WRAPPER"] = str(self.root / "missing")
        self.assertEqual(self.run_command()[1]["outcome"], "environment-gap")

    def test_command_failure_and_wrapper_teardown_distinguished(self):
        self.wrapper('exec "$@"')
        for code in (7, 125, 126, 127):
            proc, data = self.run_command(command=[sys.executable, "-c", "raise SystemExit(" + str(code) + ")"])
            self.assertEqual(proc.returncode, code)
            self.assertEqual(data["outcome"], "command-failed")
            self.assertFalse(self.slots())
        self.wrapper('"$@"\nexit 9')
        self.assertEqual(self.run_command()[1]["outcome"], "environment-gap")
        self.wrapper('exec "$@"')
        self.assertEqual(self.run_command(command=["missing-fixture-program"])[1]["outcome"], "environment-gap")

    def test_disabled_reviewers_and_qa_execute_zero_suites(self):
        marker = self.root / "executed"
        command = [sys.executable, "-c", "import pathlib,sys;pathlib.Path(sys.argv[1]).touch()", str(marker)]
        self.env["TEAM_SKILLS_REVIEWER_RUNS_TESTS"] = "false"
        for kind in ("test", "build", "lint", "e2e", "install"):
            proc, data = self.run_command(role="reviewer", kind=kind, command=command)
            self.assertEqual(data["outcome"], "skipped")
            self.assertFalse(marker.exists())
        for kind in ("test", "lint", "e2e"):
            self.run_command(role="qa", kind=kind, command=command)
            self.assertFalse(marker.exists())
        proc, _ = self.run_command(role="qa", kind="build", command=command)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertTrue(marker.exists())

    def test_minimal_rounds_post_push_and_qa_exception(self):
        self.env["TEAM_SKILLS_MINIMAL_TEST_RUNS"] = "true"
        self.assertEqual(self.run_command(scope="full")[1]["outcome"], "environment-gap")
        self.assertEqual(self.run_command()[1]["outcome"], "passed")
        for role in ("developer", "reviewer"):
            self.assertEqual(self.run_command(role=role, phase="post-push")[1]["outcome"], "skipped")
        self.assertEqual(self.run_command(role="qa", kind="flow", phase="post-push")[1]["outcome"], "passed")

    def test_final_gate_rejects_stale_dirty_and_failed_evidence(self):
        self.repository()
        self.env["TEAM_SKILLS_MINIMAL_TEST_RUNS"] = "true"
        check = [str(RUNNER), "check-gate", "--result", str(self.evidence)]
        def checked():
            return subprocess.run(check, env=self.env, cwd=self.cwd, capture_output=True).returncode
        self.assertNotEqual(checked(), 0)
        proc, data = self.run_command(phase="pre-push", scope="full")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(data["sha"], self.git("rev-parse", "HEAD"))
        self.assertEqual(checked(), 0)
        original = self.evidence.read_text()
        newer = json.loads(original)
        newer["schema_version"] = 99
        self.evidence.write_text(json.dumps(newer))
        self.assertNotEqual(checked(), 0)
        self.assertEqual(json.loads(self.evidence.read_text())["schema_version"], 99)
        self.evidence.write_text(original)
        (self.cwd / "file").write_text("new")
        self.assertNotEqual(checked(), 0)
        self.git("add", "file")
        self.git("commit", "-qm", "next")
        self.assertNotEqual(checked(), 0)
        proc, _ = self.run_command(phase="pre-push", scope="full", command=[sys.executable, "-c", "raise SystemExit(4)"])
        self.assertEqual(proc.returncode, 4)
        self.assertNotEqual(checked(), 0)
        self.run_command(phase="pre-push", scope="full")
        self.assertEqual(checked(), 0)
        self.env["TEAM_SKILLS_TEST_SLOTS"] = "1"
        self.assertNotEqual(checked(), 0)
        # Generated changes invalidate an otherwise successful gate.
        self.env.pop("TEAM_SKILLS_TEST_SLOTS")
        proc, data = self.run_command(phase="pre-push", scope="full", command=[sys.executable, "-c", "open('file','w').write('generated')"])
        self.assertEqual(data["outcome"], "environment-gap")

    def test_concurrent_packages_queue_at_n_and_release(self):
        self.env["TEAM_SKILLS_TEST_SLOTS"] = "2"
        copy = self.root / "other-package"
        shutil.copytree(PACKAGE / "scripts", copy)
        release = self.root / "release"
        command = [sys.executable, "-c", "import pathlib,sys,time;pathlib.Path(sys.argv[1]).touch();\nwhile not pathlib.Path(sys.argv[2]).exists(): time.sleep(.02)"]
        processes = []
        try:
            for index in range(3):
                args = self.args(command=command + [str(self.root / ("started" + str(index))), str(release)], result=self.root / ("result" + str(index)))
                if index == 1:
                    args[0] = str(copy / "test_runner.py")
                processes.append(subprocess.Popen(args, cwd=self.cwd, env=self.env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
                if index < 2:
                    self.wait_for(lambda: (self.root / ("started" + str(index))).exists(), processes[-1])
            time.sleep(.25)
            self.assertEqual(len(self.slots()), 2)
            self.assertFalse((self.root / "started2").exists())
            self.assertIsNone(processes[2].poll())
            release.touch()
            for process in processes:
                self.assertEqual(process.wait(timeout=10), 0)
            self.assertTrue((self.root / "started2").exists())
            self.assertFalse(self.slots())
        finally:
            for process in processes:
                if process.poll() is None:
                    process.terminate()
                process.wait(timeout=10)

    def semaphore(self, operation, run_id, capacity="2", extra=()):
        args = [str(PACKAGE / "scripts/run_lock.sh"), "sem-" + operation, "heavy", "local", "--run-id", run_id]
        if operation == "acquire":
            args += ["--capacity", capacity, "--wait", "0"]
        return subprocess.run(args + list(extra), env=self.env, capture_output=True, text=True)

    def test_semaphore_resume_stale_live_and_unknown_records(self):
        first = self.semaphore("acquire", "first")
        self.assertEqual(first.returncode, 0, first.stderr)
        second = json.loads(self.semaphore("acquire", "second").stdout)
        self.assertEqual(second["slot"], 2)
        self.assertEqual(self.semaphore("release", "first").returncode, 0)
        resumed = json.loads(self.semaphore("acquire", "second").stdout)
        self.assertEqual(resumed["slot"], 2)
        self.assertEqual(len(self.slots()), 1)
        self.semaphore("release", "second")
        self.semaphore("acquire", "stale", capacity="1")
        path = self.slots()[0] / "lease.json"
        data = json.loads(path.read_text())
        data.update(heartbeat=0, pid=os.getpid())
        path.write_text(json.dumps(data))
        self.assertEqual(self.semaphore("acquire", "next", capacity="1").returncode, 3)
        data["pid"] = None
        path.write_text(json.dumps(data))
        self.assertEqual(self.semaphore("acquire", "next", capacity="1").returncode, 0)
        self.assertEqual(self.semaphore("acquire", "other", capacity="2").returncode, 2)
        data = json.loads(path.read_text())
        data["schema_version"] = 99
        path.write_text(json.dumps(data))
        before = path.read_bytes()
        self.assertEqual(self.semaphore("acquire", "other", capacity="1").returncode, 2)
        self.assertEqual(path.read_bytes(), before)

    def test_semaphore_simultaneous_claims_and_symlink_refusal(self):
        # Start all claimers before waiting: this exercises initialization races.
        commands = []
        for index in range(6):
            args = [str(PACKAGE / "scripts/run_lock.sh"), "sem-acquire", "heavy", "local",
                    "--run-id", "r" + str(index), "--capacity", "3", "--wait", "0"]
            commands.append(subprocess.Popen(args, env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE))
        codes = []
        for child in commands:
            child.communicate(timeout=10)
            codes.append(child.returncode)
        self.assertEqual(sorted(codes), [0, 0, 0, 3, 3, 3])
        self.assertEqual(len(self.slots()), 3)
        for index in range(6):
            self.semaphore("release", "r" + str(index))
        self.assertFalse(self.slots())
        outside = self.root / "outside"
        outside.mkdir()
        queue = self.root / "state/locks/sem-heavy/local"
        (queue / "slot-1.lock").symlink_to(outside, target_is_directory=True)
        self.assertEqual(self.semaphore("acquire", "unsafe").returncode, 2)
        self.assertFalse(list(outside.iterdir()))

    def test_interrupted_waiter_releases_only_its_own_capacity(self):
        self.env["TEAM_SKILLS_TEST_SLOTS"] = "1"
        self.assertEqual(self.semaphore("acquire", "holder", capacity="1").returncode, 0)
        process = subprocess.Popen(self.args(), env=self.env, cwd=self.cwd,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            time.sleep(.3)
            self.assertIsNone(process.poll())
            process.send_signal(signal.SIGINT)
            self.assertEqual(process.wait(timeout=10), 130)
            self.assertEqual(len(self.slots()), 1)
            data = json.loads((self.slots()[0] / "lease.json").read_text())
            self.assertEqual(data["run_id"], "holder")
            self.assertEqual(json.loads(self.evidence.read_text())["outcome"], "interrupted")
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=10)
            self.semaphore("release", "holder")

    def test_heartbeat_and_interruption_release_descendants(self):
        self.env["TEAM_SKILLS_TEST_SLOTS"] = "1"
        marker = self.root / "pid"
        command = [sys.executable, "-c", "import os,time,sys;open(sys.argv[1],'w').write(str(os.getpid()));time.sleep(30)", str(marker)]
        process = subprocess.Popen(self.args(command=command), env=self.env, cwd=self.cwd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            self.wait_for(marker.exists, process)
            slot = self.slots()[0] / "lease.json"
            heartbeat = json.loads(slot.read_text())["heartbeat"]
            self.wait_for(lambda: json.loads(slot.read_text())["heartbeat"] > heartbeat, process)
            process.send_signal(signal.SIGTERM)
            self.assertEqual(process.wait(timeout=10), 143)
            self.assertFalse(self.slots())
            self.assertEqual(json.loads(self.evidence.read_text())["outcome"], "interrupted")
            # A new invocation can acquire immediately after interruption.
            self.assertEqual(self.run_command()[0].returncode, 0)
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=10)


if __name__ == "__main__":
    unittest.main()
