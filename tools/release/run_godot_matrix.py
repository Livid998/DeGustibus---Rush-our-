#!/usr/bin/env python3
"""Run the authoritative Godot scene matrix with per-scene evidence logs."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import subprocess
import sys
import time


RESULT_FILE_PATTERN = re.compile(r"^tests/(?:test-results|[^/]*-result)\.txt$")


def _git_items(project: Path, executable: str, *arguments: str) -> list[str]:
    completed = subprocess.run(
        [executable, *arguments], cwd=project, capture_output=True, check=False
    )
    if completed.returncode != 0:
        message = completed.stderr.decode("utf-8", "replace").strip()
        raise RuntimeError(message or f"git {' '.join(arguments)} failed")
    return [
        value.decode("utf-8", "surrogateescape").replace("\\", "/")
        for value in completed.stdout.split(b"\0") if value
    ]


class TestResultIsolation:
    """Restores only known test reports and exposes every other mutation."""

    def __init__(self, project: Path, git_executable: str = "git") -> None:
        self.project = project.resolve()
        self.git_executable = git_executable
        status = _git_items(
            self.project, self.git_executable,
            "status", "--porcelain=v1", "-z", "--untracked-files=normal",
        )
        if status:
            raise RuntimeError(
                "Test-result isolation requires a clean repository before the matrix; "
                "existing changes are never hidden"
            )
        tracked = _git_items(self.project, self.git_executable, "ls-files", "-z", "tests")
        self.snapshots: dict[str, bytes] = {}
        for relative in tracked:
            if RESULT_FILE_PATTERN.fullmatch(relative):
                self.snapshots[relative] = (self.project / relative).read_bytes()

    @staticmethod
    def is_result_file(relative: str) -> bool:
        return RESULT_FILE_PATTERN.fullmatch(relative.replace("\\", "/")) is not None

    def restore(self) -> list[str]:
        violations: list[str] = []
        changed = set(_git_items(
            self.project, self.git_executable, "diff", "--name-only", "-z", "--",
        ))
        staged = set(_git_items(
            self.project, self.git_executable, "diff", "--cached", "--name-only", "-z", "--",
        ))
        for relative in sorted(staged):
            violations.append(f"test staged a file and the index was not altered: {relative}")
        changed.update(staged)
        for relative in sorted(changed):
            if not self.is_result_file(relative) or relative not in self.snapshots:
                violations.append(f"test mutated tracked non-result file: {relative}")
                continue
            target = (self.project / relative).resolve()
            if not target.is_relative_to(self.project):
                violations.append(f"unsafe result path: {relative}")
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(self.snapshots[relative])

        untracked = _git_items(
            self.project, self.git_executable,
            "ls-files", "--others", "--exclude-standard", "-z",
        )
        for relative in sorted(untracked):
            if not self.is_result_file(relative):
                violations.append(f"test created untracked non-result file: {relative}")
                continue
            target = (self.project / relative).resolve()
            if not target.is_relative_to(self.project) or not target.is_file():
                violations.append(f"unsafe generated result path: {relative}")
                continue
            target.unlink()
        if not violations:
            remaining = _git_items(
                self.project, self.git_executable,
                "status", "--porcelain=v1", "-z", "--untracked-files=normal",
            )
            if remaining:
                violations.append("worktree is not clean after isolated result restoration")
        return violations


def parse_matrix(path: Path) -> dict[str, list[str]]:
    groups: dict[str, list[str]] = {}
    current = ""
    for line_number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            current = line[1:-1].strip().lower()
            if not current or current in groups:
                raise ValueError(f"Invalid/duplicate group on line {line_number}: {line}")
            groups[current] = []
            continue
        if not current or not line.startswith("res://") or not line.endswith(".tscn"):
            raise ValueError(f"Invalid matrix entry on line {line_number}: {line}")
        if any(line in scenes for scenes in groups.values()):
            raise ValueError(f"Scene appears more than once: {line}")
        groups[current].append(line)
    if not groups or any(not scenes for scenes in groups.values()):
        raise ValueError("Every matrix group must contain at least one scene")
    return groups


def safe_name(scene: str) -> str:
    return Path(scene.removeprefix("res://")).stem.replace("-", "_")


def run_scenes(args, project: Path, groups: dict[str, list[str]], selected: list[str], log_root: Path) -> int:
    summary: list[str] = []
    total_started = time.monotonic()
    for group in selected:
        for scene in groups[group]:
            resource_path = project / scene.removeprefix("res://")
            if not resource_path.is_file():
                print(f"Matrix scene does not exist: {scene}", file=sys.stderr)
                return 2
            label = f"{group}-{safe_name(scene)}"
            stdout_path = log_root / f"{label}.log"
            engine_path = log_root / f"{label}.godot.log"
            command = [
                str(args.godot.resolve()), "--headless", "--path", str(project),
                "--log-file", str(engine_path.resolve()), "--scene", scene,
            ]
            started = time.monotonic()
            print(f"::group::{group} / {scene}", flush=True)
            try:
                scene_environment = os.environ.copy()
                scene_environment["DEGUSTIBUS_RELEASE_EVIDENCE_DIR"] = str(log_root.resolve())
                completed = subprocess.run(
                    command, cwd=project, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                    text=True, encoding="utf-8", errors="replace", timeout=args.timeout,
                    env=scene_environment, check=False,
                )
                output = completed.stdout or ""
                stdout_path.write_text(output, encoding="utf-8")
                duration = time.monotonic() - started
                summary.append(f"{group}\t{scene}\t{completed.returncode}\t{duration:.2f}")
                tail = "\n".join(output.splitlines()[-35:])
                if tail:
                    print(tail)
                print("::endgroup::", flush=True)
                if completed.returncode != 0:
                    print(f"FAILED: {scene}; full output: {stdout_path}", file=sys.stderr)
                    return completed.returncode or 1
            except subprocess.TimeoutExpired as error:
                output = error.stdout or ""
                if isinstance(output, bytes):
                    output = output.decode("utf-8", "replace")
                stdout_path.write_text(output + f"\nTIMEOUT after {args.timeout}s\n", encoding="utf-8")
                summary.append(f"{group}\t{scene}\ttimeout\t{args.timeout}")
                print("::endgroup::", flush=True)
                print(f"TIMEOUT: {scene}; full output: {stdout_path}", file=sys.stderr)
                return 124
            finally:
                (log_root / "matrix-summary.tsv").write_text(
                    "group\tscene\texit\tseconds\n" + "\n".join(summary) + "\n",
                    encoding="utf-8",
                )
    elapsed = time.monotonic() - total_started
    print(f"Release matrix passed: {len(summary)} scenes in {elapsed:.1f}s")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot", required=True, type=Path)
    parser.add_argument("--project", default=".", type=Path)
    parser.add_argument("--matrix", default="tools/release/test_matrix.txt", type=Path)
    parser.add_argument("--groups", default="all", help="Comma-separated groups or 'all'")
    parser.add_argument("--logs", default="release-evidence/godot", type=Path)
    parser.add_argument("--timeout", default=420, type=int, help="Seconds per scene")
    parser.add_argument("--isolate-test-results", action="store_true")
    parser.add_argument("--git", default="git")
    args = parser.parse_args()

    project = args.project.resolve()
    matrix_path = args.matrix if args.matrix.is_absolute() else project / args.matrix
    log_root = args.logs if args.logs.is_absolute() else project / args.logs
    groups = parse_matrix(matrix_path)
    selected = list(groups) if args.groups.strip().lower() == "all" else [
        value.strip().lower() for value in args.groups.split(",") if value.strip()
    ]
    unknown = [value for value in selected if value not in groups]
    if unknown:
        raise SystemExit(f"Unknown matrix groups: {', '.join(unknown)}")
    if not args.godot.is_file():
        raise SystemExit(f"Godot executable not found: {args.godot}")

    log_root.mkdir(parents=True, exist_ok=True)
    isolation = TestResultIsolation(project, args.git) if args.isolate_test_results else None
    result = 1
    isolation_violations: list[str] = []
    try:
        result = run_scenes(args, project, groups, selected, log_root)
    finally:
        if isolation is not None:
            isolation_violations = isolation.restore()
    if isolation_violations:
        print("Test worktree isolation failed:", file=sys.stderr)
        for violation in isolation_violations:
            print(f"- {violation}", file=sys.stderr)
        return 2
    return result


if __name__ == "__main__":
    raise SystemExit(main())
