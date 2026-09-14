#!/usr/bin/env python3
"""Run one iOS stories-mode bmad-loop pass with an unattended plan gate."""

from __future__ import annotations

import argparse
import json
import shlex
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Any


DEFAULT_SPEC = "_bmad-output/implementation-artifacts/next-wave-standard-hermes-migration"
PLAN_CHECKPOINT = "plan-checkpoint"
VERDICT_NAME = "spec-review-verdict.json"


def display_path(path: Path) -> str:
    home = Path.home()
    try:
        return "~" + str(path.resolve().relative_to(home))
    except ValueError:
        return str(path)


def json_command(binary: str, args: list[str], project: Path) -> dict[str, Any]:
    completed = subprocess.run(
        [binary, *args], cwd=project, check=False, capture_output=True, text=True
    )
    if completed.stderr:
        print(completed.stderr, file=sys.stderr, end="")
    if completed.returncode:
        raise RuntimeError(
            f"{shlex.join([binary, *args])} failed with exit code {completed.returncode}"
        )
    try:
        document = json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError("bmad-loop returned invalid JSON") from exc
    if not isinstance(document, dict):
        raise RuntimeError("bmad-loop returned a non-object JSON value")
    return document


def run_ids(binary: str, project: Path) -> set[str]:
    document = json_command(binary, ["list", "--project", str(project), "--json"], project)
    runs = document.get("runs")
    if not isinstance(runs, list):
        raise RuntimeError("bmad-loop list JSON did not contain a runs list")
    return {
        str(item["run_id"])
        for item in runs
        if isinstance(item, dict) and isinstance(item.get("run_id"), str)
    }


def status(binary: str, project: Path, run_id: str) -> dict[str, Any]:
    return json_command(
        binary, ["status", "--project", str(project), "--json", run_id], project
    )


def story_is_present(document: dict[str, Any], story: str) -> bool:
    if document.get("paused_story_key") == story:
        return True
    tasks = document.get("tasks")
    return isinstance(tasks, list) and any(
        isinstance(task, dict) and task.get("story_key") == story for task in tasks
    )


def wait_for_story_run(
    binary: str,
    project: Path,
    before: set[str],
    story: str,
    timeout: float,
    poll_interval: float,
) -> tuple[str, dict[str, Any]] | None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        document = json_command(binary, ["list", "--project", str(project), "--json"], project)
        runs = document.get("runs")
        if not isinstance(runs, list):
            raise RuntimeError("bmad-loop list JSON did not contain a runs list")
        matching = []
        for item in runs:
            if not isinstance(item, dict) or not isinstance(item.get("run_id"), str):
                continue
            if item["run_id"] in before:
                continue
            run_id = item["run_id"]
            run_status = status(binary, project, run_id)
            if story_is_present(run_status, story):
                matching.append((run_id, run_status))
        if len(matching) == 1:
            return matching[0]
        if len(matching) > 1:
            raise RuntimeError(f"multiple new runs claim story {story!r}")
        time.sleep(poll_interval)
    return None


def wait_for_verdict(
    project: Path, run_id: str, story: str, timeout: float, poll_interval: float
) -> tuple[dict[str, Any] | None, Path]:
    verdict_path = project / ".bmad-loop" / "runs" / run_id / VERDICT_NAME
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if verdict_path.is_file():
            try:
                verdict = json.loads(verdict_path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as exc:
                raise RuntimeError(f"unreadable reviewer verdict: {exc}") from exc
            if not isinstance(verdict, dict):
                raise RuntimeError("review verdict is not a JSON object")
            if verdict.get("story_key") != story:
                raise RuntimeError(
                    f"review verdict is for {verdict.get('story_key')!r}, not {story!r}"
                )
            return verdict, verdict_path
        time.sleep(poll_interval)
    return None, verdict_path


def run_foreground(binary: str, args: list[str], project: Path) -> int:
    print(f"$ {shlex.join([binary, *args])}", file=sys.stderr)
    return subprocess.run([binary, *args], cwd=project, check=False).returncode


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Run one iOS stories-mode bmad-loop story and auto-resume a passed plan review."
    )
    parser.add_argument("--project", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--spec", default=DEFAULT_SPEC)
    parser.add_argument("--story", default="0-I-4")
    parser.add_argument("--poll-interval", type=float, default=0.5)
    parser.add_argument("--discovery-timeout", type=float, default=15.0)
    parser.add_argument("--verdict-timeout", type=float, default=10.0)
    parser.add_argument("--no-resume", action="store_true")
    args = parser.parse_args(argv)
    if min(args.poll_interval, args.discovery_timeout, args.verdict_timeout) <= 0:
        parser.error("poll and timeout values must be positive")

    project = args.project.expanduser().resolve()
    binary = shutil.which("bmad-loop")
    if binary is None:
        print("bmad-loop is not installed", file=sys.stderr)
        return 2
    try:
        validation = json_command(
            binary,
            ["validate", "--project", str(project), "--spec", args.spec, "--json"],
            project,
        )
        if not validation.get("ok"):
            print("bmad-loop preflight failed; nothing was started", file=sys.stderr)
            return 2
        before = run_ids(binary, project)
        run_rc = run_foreground(
            binary,
            ["run", "--project", str(project), "--spec", args.spec, "--story", args.story],
            project,
        )
        if run_rc:
            print(f"bmad-loop run stopped with exit code {run_rc}; not resuming", file=sys.stderr)
            return run_rc
        found = wait_for_story_run(
            binary,
            project,
            before,
            args.story,
            args.discovery_timeout,
            args.poll_interval,
        )
        if found is None:
            print(f"could not identify the new run for story {args.story!r}; not resuming", file=sys.stderr)
            return 3
        run_id, run_status = found
        if run_status.get("status") != "paused" or run_status.get("paused_stage") != PLAN_CHECKPOINT:
            print(
                f"run {run_id} did not pause at the plan checkpoint "
                f"(status={run_status.get('status')!r}, paused_stage={run_status.get('paused_stage')!r})",
                file=sys.stderr,
            )
            return 3
        verdict, verdict_path = wait_for_verdict(
            project, run_id, args.story, args.verdict_timeout, args.poll_interval
        )
        if verdict is None:
            print(f"no reviewer verdict at {display_path(verdict_path)}; plan remains paused", file=sys.stderr)
            return 4
        if verdict.get("status") != "pass" or verdict.get("phase") != "plan":
            print(f"spec reviewer returned {verdict.get('status')!r}; plan remains paused", file=sys.stderr)
            return 4
        print(f"spec reviewer passed; resuming run {run_id}", file=sys.stderr)
        if args.no_resume:
            return 0
        return run_foreground(binary, ["resume", "--project", str(project), run_id], project)
    except (OSError, RuntimeError) as exc:
        print(f"bmad-loop supervisor: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
