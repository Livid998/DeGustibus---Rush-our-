#!/usr/bin/env python3
"""Unit smoke for worktree isolation and strict browser error policy."""

from __future__ import annotations

import importlib.util
import argparse
from pathlib import Path
import subprocess
import sys
import tempfile


HERE = Path(__file__).resolve().parent
sys.dont_write_bytecode = True


def load_module(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot load {filename}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def git(root: Path, executable: str, *arguments: str) -> None:
    subprocess.run([executable, *arguments], cwd=root, check=True, capture_output=True)


def test_result_isolation(runner, git_executable: str) -> None:
    with tempfile.TemporaryDirectory(prefix="degustibus-release-tools-") as raw:
        root = Path(raw)
        (root / "tests").mkdir()
        result = root / "tests" / "sample-result.txt"
        source = root / "tests" / "source.gd"
        result.write_text("original\n", encoding="utf-8")
        source.write_text("extends Node\n", encoding="utf-8")
        git(root, git_executable, "init", "-q")
        git(root, git_executable, "config", "user.email", "release-smoke@example.invalid")
        git(root, git_executable, "config", "user.name", "Release Smoke")
        git(root, git_executable, "add", "tests")
        git(root, git_executable, "commit", "-qm", "fixture")

        isolation = runner.TestResultIsolation(root, git_executable)
        result.write_text("generated output\n", encoding="utf-8")
        generated = root / "tests" / "new-result.txt"
        generated.write_text("temporary\n", encoding="utf-8")
        assert isolation.restore() == []
        assert result.read_text(encoding="utf-8") == "original\n"
        assert not generated.exists()
        assert subprocess.run([git_executable, "status", "--porcelain"], cwd=root, capture_output=True, text=True).stdout == ""

        isolation = runner.TestResultIsolation(root, git_executable)
        source.write_text("extends Node\n# unexpected mutation\n", encoding="utf-8")
        violations = isolation.restore()
        assert violations == ["test mutated tracked non-result file: tests/source.gd"]
        assert "unexpected mutation" in source.read_text(encoding="utf-8")

    with tempfile.TemporaryDirectory(prefix="degustibus-release-index-") as raw:
        root = Path(raw)
        (root / "tests").mkdir()
        result = root / "tests" / "sample-result.txt"
        result.write_text("original\n", encoding="utf-8")
        git(root, git_executable, "init", "-q")
        git(root, git_executable, "config", "user.email", "release-smoke@example.invalid")
        git(root, git_executable, "config", "user.name", "Release Smoke")
        git(root, git_executable, "add", "tests")
        git(root, git_executable, "commit", "-qm", "fixture")
        isolation = runner.TestResultIsolation(root, git_executable)
        result.write_text("generated and staged\n", encoding="utf-8")
        git(root, git_executable, "add", "tests/sample-result.txt")
        violations = isolation.restore()
        assert any("test staged a file" in value for value in violations)


def test_browser_error_policy(browser) -> None:
    favicon = {
        "text": "Failed to load resource: the server responded with a status of 404 (File not found)",
        "location": {"url": "http://127.0.0.1:4173/favicon.ico"},
    }
    missing_pck = {
        "text": "Failed to load resource: the server responded with a status of 404 (File not found)",
        "location": {"url": "http://127.0.0.1:4173/index.pck"},
    }
    assert browser.significant_browser_errors([], [favicon]) == []
    assert len(browser.significant_browser_errors([], [missing_pck])) == 1
    assert browser.significant_browser_errors(["ReferenceError: broken"], []) == [
        "pageerror: ReferenceError: broken"
    ]
    assert len(browser.BENIGN_CONSOLE_ERROR_RULES) == 1


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--git", default="git")
    args = parser.parse_args()
    runner = load_module("release_matrix_runner", "run_godot_matrix.py")
    browser = load_module("release_browser_smoke", "browser_smoke.py")
    test_result_isolation(runner, args.git)
    test_browser_error_policy(browser)
    print("RELEASE TOOLS SMOKE: PASS | isolation=5 browser_policy=4")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
