#!/usr/bin/env python3
"""Finalize a Godot Web export without rebuilding it."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import re
import shutil
import subprocess


PRECACHE_ADDITIONS = (
    "index.manifest.json",
    "index.144x144.png",
    "index.180x180.png",
    "index.192x192.png",
    "index.512x512.png",
    "build-info.json",
)


def git_output(project: Path, executable: str, *arguments: str) -> str:
    completed = subprocess.run(
        [executable, *arguments], cwd=project, capture_output=True, text=True, check=False
    )
    if completed.returncode != 0:
        raise RuntimeError(completed.stderr.strip() or "git command failed")
    return completed.stdout.strip()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project", default=".", type=Path)
    parser.add_argument("--build", default="builds/pwa", type=Path)
    parser.add_argument("--commit", default="")
    parser.add_argument("--godot-version", required=True)
    parser.add_argument("--release", required=True)
    parser.add_argument("--mode", choices=("release", "debug"), default="release")
    parser.add_argument("--require-clean", action="store_true")
    parser.add_argument("--git", default="git", help="Git executable used for source-state proof")
    args = parser.parse_args()

    project = args.project.resolve()
    build = args.build if args.build.is_absolute() else project / args.build
    build = build.resolve()
    if project not in build.parents:
        raise SystemExit(f"Unsafe build path outside project: {build}")

    commit = args.commit.strip()
    dirty: bool | None = None
    try:
        if not commit:
            commit = git_output(project, args.git, "rev-parse", "HEAD")
        dirty = bool(git_output(project, args.git, "status", "--porcelain", "--untracked-files=normal"))
    except (FileNotFoundError, RuntimeError):
        if args.require_clean:
            raise SystemExit("Git is required to prove a publishable clean artifact")
    if args.require_clean and dirty is not False:
        raise SystemExit("Refusing a release artifact from a dirty or unverifiable repository")

    manifest_path = build / "index.manifest.json"
    worker_path = build / "index.service.worker.js"
    if not manifest_path.is_file() or not worker_path.is_file():
        raise SystemExit("Godot Web export is incomplete before post-processing")
    shutil.copyfile(project / "web" / "pwa_icon_192.png", build / "index.192x192.png")

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest.update({"orientation": "any", "id": "./", "scope": "./"})
    icons = [icon for icon in manifest.get("icons", []) if icon.get("sizes") != "192x192"]
    icons.append({
        "sizes": "192x192", "src": "index.192x192.png", "type": "image/png", "purpose": "any"
    })
    for icon in icons:
        icon["purpose"] = "any"
    icons.sort(key=lambda icon: int(str(icon["sizes"]).split("x", 1)[0]))
    manifest["icons"] = icons
    manifest_path.write_text(
        json.dumps(manifest, ensure_ascii=False, separators=(",", ":")), encoding="utf-8"
    )

    build_info = {
        "app_id": "degustibus-rush-hour",
        "commit": commit,
        "godot_version": args.godot_version.strip(),
        "built_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "release": args.release.strip(),
        "dirty": False if args.require_clean else dirty,
        "source_state": "clean" if dirty is False else ("dirty" if dirty else "unknown"),
        "mode": args.mode,
        "offline_cache": "runtime-cache-after-first-controlled-load",
    }
    (build / "build-info.json").write_text(
        json.dumps(build_info, ensure_ascii=False, indent=2), encoding="utf-8"
    )

    worker = worker_path.read_text(encoding="utf-8")
    cached_match = re.search(r"const CACHED_FILES = (?P<files>\[[^\r\n]*\]);", worker)
    cacheable_match = re.search(r"const CACHEABLE_FILES = (?P<files>\[[^\r\n]*\]);", worker)
    if cached_match is None or cacheable_match is None or "cache.addAll(CACHED_FILES)" not in worker:
        raise SystemExit("Unrecognized Godot service worker")
    cached = json.loads(cached_match.group("files"))
    for asset in PRECACHE_ADDITIONS:
        if asset not in cached:
            cached.append(asset)
    declaration = "const CACHED_FILES = " + json.dumps(cached, separators=(",", ":")) + ";"
    worker = worker[: cached_match.start()] + declaration + worker[cached_match.end() :]
    marker = "// DeGustibus first-install control"
    if marker not in worker:
        worker += """

// DeGustibus first-install control: claim the already-open page only when
// there is no previous active worker. Later updates wait for the explicit UI.
self.addEventListener('install', (event) => {
    if (!self.registration.active) event.waitUntil(self.skipWaiting());
});
self.addEventListener('activate', (event) => {
    event.waitUntil(self.clients.claim());
});
"""
    worker_path.write_text(worker, encoding="utf-8")
    (build / ".nojekyll").write_text("", encoding="utf-8")
    print(json.dumps(build_info, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
