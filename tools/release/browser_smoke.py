#!/usr/bin/env python3
"""Reproducible Chromium + WebKit smoke against the exact release artifact."""

from __future__ import annotations

import argparse
import asyncio
import json
from pathlib import Path
import time
import urllib.request


# Only a missing implicit browser favicon is benign. Missing game resources,
# JavaScript exceptions and every other console error remain release blockers.
BENIGN_CONSOLE_ERROR_RULES = (
    "missing implicit favicon.ico",
)


def is_benign_console_error(text: str, location: dict | None = None) -> bool:
    location_url = str((location or {}).get("url", "")).split("?", 1)[0]
    return (
        location_url.endswith("/favicon.ico")
        and "failed to load resource" in text.lower()
        and "404" in text
    )


def significant_browser_errors(page_errors: list[str], console_errors: list[dict]) -> list[str]:
    significant = [f"pageerror: {value}" for value in page_errors]
    for event in console_errors:
        if not is_benign_console_error(str(event.get("text", "")), event.get("location", {})):
            significant.append(f"console error: {event.get('text', '')} @ {event.get('location', {})}")
    return significant


async def smoke_browser(playwright, browser_name: str, base_url: str) -> dict:
    browser_type = getattr(playwright, browser_name)
    browser = await browser_type.launch(headless=True)
    page_errors: list[str] = []
    console_errors: list[dict] = []
    started = time.monotonic()
    try:
        context = await browser.new_context(viewport={"width": 800, "height": 1024})
        page = await context.new_page()
        page.on("pageerror", lambda error: page_errors.append(str(error)))

        def record_console(message) -> None:
            if message.type == "error":
                console_errors.append({"text": message.text, "location": message.location})

        page.on("console", record_console)
        response = await page.goto(base_url + "/index.html", wait_until="domcontentloaded", timeout=120_000)
        if response is None or response.status >= 400:
            raise RuntimeError(f"index response status: {None if response is None else response.status}")
        await page.wait_for_selector("canvas", state="attached", timeout=120_000)
        await page.wait_for_function(
            """() => {
                const canvas = document.querySelector('canvas');
                return canvas && canvas.width > 0 && canvas.height > 0;
            }""",
            timeout=120_000,
        )
        await page.wait_for_timeout(5_000)
        significant_errors = significant_browser_errors(page_errors, console_errors)
        if significant_errors:
            raise RuntimeError("; ".join(significant_errors))
        canvas = await page.locator("canvas").evaluate(
            "canvas => ({width: canvas.width, height: canvas.height})"
        )
        benign = [event for event in console_errors if is_benign_console_error(event["text"], event["location"])]
        return {
            "browser": browser_name,
            "status": "pass",
            "seconds": round(time.monotonic() - started, 3),
            "canvas": canvas,
            "page_errors": [],
            "console_errors": [],
            "benign_console_errors": benign,
        }
    finally:
        await browser.close()


async def run(args) -> int:
    from playwright.async_api import async_playwright

    with urllib.request.urlopen(args.base_url.rstrip("/") + "/build-info.json", timeout=20) as response:
        info = json.load(response)
    if info.get("dirty") is not False or not info.get("commit") or not info.get("release"):
        raise SystemExit("Browser smoke refuses an unversioned or dirty artifact")

    results = []
    async with async_playwright() as playwright:
        for browser_name in ("chromium", "webkit"):
            try:
                results.append(await smoke_browser(playwright, browser_name, args.base_url.rstrip("/")))
            except Exception as error:
                results.append({"browser": browser_name, "status": "fail", "error": str(error)})
    evidence = {"build_info": info, "results": results}
    payload = json.dumps(evidence, ensure_ascii=False, indent=2)
    print(payload)
    args.evidence.parent.mkdir(parents=True, exist_ok=True)
    args.evidence.write_text(payload + "\n", encoding="utf-8")
    return 0 if all(item["status"] == "pass" for item in results) else 1


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default="http://127.0.0.1:4173")
    parser.add_argument("--evidence", default=Path("release-evidence/browser-smoke.json"), type=Path)
    return asyncio.run(run(parser.parse_args()))


if __name__ == "__main__":
    raise SystemExit(main())
