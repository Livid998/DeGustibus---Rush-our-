#!/usr/bin/env python3
"""Validate publishability and hard size budgets of an existing PWA artifact."""

from __future__ import annotations

import argparse
import datetime as dt
import json
from pathlib import Path
import re
import struct


MIB = 1024 * 1024
REQUIRED = (
    "index.html", "index.js", "index.wasm", "index.pck",
    "index.service.worker.js", "index.manifest.json",
    "index.192x192.png", "index.512x512.png", "build-info.json", ".nojekyll",
)


def png_dimensions(path: Path) -> tuple[int, int]:
    value = path.read_bytes()
    if value[:8] != b"\x89PNG\r\n\x1a\n" or len(value) < 24:
        raise ValueError(f"{path.name} is not a valid PNG")
    return struct.unpack(">II", value[16:24])


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--build", default="builds/pwa", type=Path)
    parser.add_argument("--require-publishable", action="store_true")
    parser.add_argument("--evidence", type=Path)
    parser.add_argument("--max-total-mib", type=float, default=65.0)
    parser.add_argument("--max-wasm-mib", type=float, default=42.0)
    parser.add_argument("--max-pck-mib", type=float, default=25.0)
    args = parser.parse_args()
    build = args.build.resolve()

    missing = [name for name in REQUIRED if not (build / name).is_file()]
    if missing:
        raise SystemExit(f"Missing PWA files: {', '.join(missing)}")

    sizes = {path.name: path.stat().st_size for path in build.rglob("*") if path.is_file()}
    total = sum(sizes.values())
    violations = []
    for label, actual, maximum in (
        ("total", total, args.max_total_mib * MIB),
        ("WASM", sizes["index.wasm"], args.max_wasm_mib * MIB),
        ("PCK", sizes["index.pck"], args.max_pck_mib * MIB),
    ):
        if actual > maximum:
            violations.append(f"{label} {actual / MIB:.2f} MiB > {maximum / MIB:.2f} MiB")
    if violations:
        raise SystemExit("Hard release budget exceeded: " + "; ".join(violations))

    manifest = json.loads((build / "index.manifest.json").read_text(encoding="utf-8"))
    icon_sizes = {str(icon.get("sizes", "")) for icon in manifest.get("icons", [])}
    if manifest.get("orientation") != "any" or manifest.get("id") != "./" or manifest.get("scope") != "./":
        raise SystemExit("Manifest id/scope/orientation contract is invalid")
    if not {"192x192", "512x512"}.issubset(icon_sizes):
        raise SystemExit("Manifest lacks install icons 192x192 or 512x512")
    if png_dimensions(build / "index.192x192.png") != (192, 192):
        raise SystemExit("Dedicated 192x192 icon has invalid dimensions")
    if png_dimensions(build / "index.512x512.png") != (512, 512):
        raise SystemExit("512x512 icon has invalid dimensions")

    worker = (build / "index.service.worker.js").read_text(encoding="utf-8")
    cached_match = re.search(r"const CACHED_FILES = (?P<files>\[[^\r\n]*\]);", worker)
    cacheable_match = re.search(r"const CACHEABLE_FILES = (?P<files>\[[^\r\n]*\]);", worker)
    if cached_match is None or cacheable_match is None:
        raise SystemExit("Service worker cache declarations are missing")
    cached = set(json.loads(cached_match.group("files")))
    cacheable = set(json.loads(cacheable_match.group("files")))
    if not {"build-info.json", "index.manifest.json", "index.192x192.png"}.issubset(cached):
        raise SystemExit("Service worker does not precache the release shell metadata")
    if not {"index.wasm", "index.pck"}.issubset(cacheable):
        raise SystemExit("WASM/PCK must remain cache-on-demand")
    if "DeGustibus first-install control" not in worker or "self.clients.claim()" not in worker:
        raise SystemExit("Controlled first-install/update flow is missing")

    info = json.loads((build / "build-info.json").read_text(encoding="utf-8"))
    required_info = ("app_id", "commit", "godot_version", "built_at_utc", "release", "dirty")
    absent = [key for key in required_info if key not in info]
    if absent:
        raise SystemExit("build-info lacks: " + ", ".join(absent))
    try:
        dt.datetime.fromisoformat(str(info["built_at_utc"]).replace("Z", "+00:00"))
    except ValueError as error:
        raise SystemExit("build-info timestamp is not ISO-8601") from error
    if args.require_publishable:
        if info.get("dirty") is not False or info.get("mode") != "release":
            raise SystemExit("Publishable artifacts require dirty:false and mode:release")
        if not str(info.get("commit", "")).strip() or not str(info.get("release", "")).strip():
            raise SystemExit("Publishable artifacts require commit and release identifiers")

    evidence = {
        "status": "pass",
        "build_info": info,
        "budgets_mib": {
            "total": round(total / MIB, 3),
            "wasm": round(sizes["index.wasm"] / MIB, 3),
            "pck": round(sizes["index.pck"] / MIB, 3),
            "limits": {"total": args.max_total_mib, "wasm": args.max_wasm_mib, "pck": args.max_pck_mib},
        },
    }
    payload = json.dumps(evidence, ensure_ascii=False, indent=2)
    print(payload)
    if args.evidence:
        args.evidence.parent.mkdir(parents=True, exist_ok=True)
        args.evidence.write_text(payload + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
