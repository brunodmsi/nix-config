#!/usr/bin/env python3
"""Headless browser page renderer — takes URLs, returns visible text.

Usage:
    car-search.py URL [URL ...]
    car-search.py https://www.webmotors.com.br/carros-usados/pa-belem/honda/civic https://www.olx.com.br/autos-e-pecas/carros-vans-e-utilitarios/honda/civic/estado-pa/regiao-de-belem

Returns JSON array of {url, content} for each URL.
Content is the visible text after JS rendering.
"""
import json
import sys
import os
import time


def crawl_page(page, url, timeout=15000):
    """Navigate to URL, wait for JS, return visible text."""
    try:
        page.goto(url, wait_until="domcontentloaded", timeout=timeout)
        # Wait for dynamic content but don't wait forever
        page.wait_for_timeout(3000)
        text = page.inner_text("body")
        return text[:20000]
    except Exception as e:
        return f"ERROR: {e}"


def main():
    urls = sys.argv[1:]
    if not urls:
        print(json.dumps({"error": "Provide one or more URLs as arguments"}))
        sys.exit(1)

    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        print(json.dumps({"error": "playwright not installed"}))
        sys.exit(1)

    try:
        from playwright_stealth import stealth_sync
        has_stealth = True
    except ImportError:
        has_stealth = False

    results = []

    with sync_playwright() as p:
        chromium_path = os.environ.get("PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH")
        browser = p.chromium.launch(
            headless=True,
            executable_path=chromium_path,
            args=["--no-sandbox", "--disable-blink-features=AutomationControlled"]
        )
        context = browser.new_context(
            user_agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            viewport={"width": 1366, "height": 768},
            locale="pt-BR",
        )
        page = context.new_page()

        if has_stealth:
            stealth_sync(page)

        for url in urls:
            content = crawl_page(page, url)
            results.append({"url": url, "content": content})
            time.sleep(1)

        browser.close()

    print(json.dumps(results, ensure_ascii=False))


if __name__ == "__main__":
    main()
