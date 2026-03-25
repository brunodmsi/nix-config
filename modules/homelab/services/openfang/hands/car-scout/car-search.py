#!/usr/bin/env python3
"""Car listing scraper — renders JS-heavy pages with Playwright and extracts visible text.

Usage:
    car-search.py --config /persist/openfang/car-scout/searches.json
    car-search.py --url "https://www.webmotors.com.br/carros-usados/pa-belem/honda/civic"

Returns JSON array of {platform, model, url, content} for each crawled page.
The Hand (LLM) parses the text content to extract individual listings.
"""
import argparse
import json
import sys
import os
import time

# Platform URL builders
# Each returns a search results URL for a given make/model in a location

def webmotors_url(model, location, state="pa", **kw):
    """WebMotors: /carros-usados/{state}-{city}/{make}/{model}"""
    city = location.lower().replace(" ", "-").replace("ã", "a").replace("é", "e")
    # Common makes for each model
    make = guess_make(model)
    return f"https://www.webmotors.com.br/carros-usados/{state}-{city}/{make}/{model}"


def olx_url(model, location, state="pa", **kw):
    """OLX: /autos-e-pecas/carros-vans-e-utilitarios/{make}/{model}/estado-{state}/regiao-de-{city}"""
    city = location.lower().replace(" ", "-").replace("ã", "a").replace("é", "e")
    make = guess_make(model)
    return f"https://www.olx.com.br/autos-e-pecas/carros-vans-e-utilitarios/{make}/{model}/estado-{state}/regiao-de-{city}"


def mobiauto_url(model, location, state="pa", **kw):
    """Mobiauto: /comprar/carros-usados/{state}-{city}/{make}/{model}"""
    city = location.lower().replace(" ", "-").replace("ã", "a").replace("é", "e")
    make = guess_make(model)
    return f"https://www.mobiauto.com.br/comprar/carros-usados/{state}-{city}/{make}/{model}"


def generic_url(platform, model, location, **kw):
    """Fallback: just search on the platform domain."""
    make = guess_make(model)
    return f"https://www.{platform}/search?q={make}+{model}+{location}"


# Model -> make mapping (common Brazilian market cars)
MAKE_MAP = {
    "civic": "honda", "hr-v": "honda", "hrv": "honda", "fit": "honda",
    "city": "honda", "accord": "honda", "cr-v": "honda", "crv": "honda",
    "corolla": "toyota", "yaris": "toyota", "hilux": "toyota",
    "corolla-cross": "toyota", "sw4": "toyota", "rav4": "toyota",
    "onix": "chevrolet", "tracker": "chevrolet", "cruze": "chevrolet",
    "s10": "chevrolet", "spin": "chevrolet", "equinox": "chevrolet",
    "polo": "volkswagen", "golf": "volkswagen", "t-cross": "volkswagen",
    "tcross": "volkswagen", "nivus": "volkswagen", "jetta": "volkswagen",
    "argo": "fiat", "pulse": "fiat", "fastback": "fiat", "toro": "fiat",
    "mobi": "fiat", "cronos": "fiat", "strada": "fiat",
    "kicks": "nissan", "sentra": "nissan", "versa": "nissan",
    "creta": "hyundai", "hb20": "hyundai", "tucson": "hyundai",
    "renegade": "jeep", "compass": "jeep", "commander": "jeep",
    "duster": "renault", "kwid": "renault", "captur": "renault",
}


def guess_make(model):
    model_lower = model.lower().replace(" ", "-")
    return MAKE_MAP.get(model_lower, model_lower)


# State mapping for Brazilian cities
CITY_STATE = {
    "belem": "pa", "belém": "pa", "manaus": "am", "macapa": "ap",
    "sao-paulo": "sp", "são paulo": "sp", "rio-de-janeiro": "rj",
    "belo-horizonte": "mg", "brasilia": "df", "curitiba": "pr",
    "porto-alegre": "rs", "recife": "pe", "fortaleza": "ce",
    "salvador": "ba", "goiania": "go", "campinas": "sp",
    "florianopolis": "sc", "vitoria": "es", "natal": "rn",
}


def guess_state(location):
    loc = location.lower().replace("ã", "a").replace("é", "e").replace(" ", "-")
    return CITY_STATE.get(loc, "")


PLATFORM_BUILDERS = {
    "webmotors.com.br": webmotors_url,
    "olx.com.br": olx_url,
    "mobiauto.com.br": mobiauto_url,
}


def build_urls(searches):
    """Build all URLs from the searches config."""
    urls = []
    for search in searches:
        location = search.get("location", "")
        state = search.get("state", "") or guess_state(location)
        platforms = search.get("platforms", [])
        models = search.get("models", [])

        for platform in platforms:
            builder = PLATFORM_BUILDERS.get(platform, None)
            for model in models:
                if builder:
                    url = builder(model=model, location=location, state=state)
                else:
                    url = generic_url(platform=platform, model=model, location=location)
                urls.append({
                    "url": url,
                    "platform": platform,
                    "model": model,
                    "location": location,
                    "budget_min": search.get("budget_min"),
                    "budget_max": search.get("budget_max"),
                    "currency": search.get("currency", "BRL"),
                })
    return urls


def crawl_page(page, url, timeout=30000):
    """Navigate to URL, wait for JS, return visible text."""
    try:
        page.goto(url, wait_until="networkidle", timeout=timeout)
        # Extra wait for lazy-loaded content
        page.wait_for_timeout(2000)
        # Get visible text (no HTML tags)
        text = page.inner_text("body")
        return text[:30000]  # Cap to avoid huge outputs
    except Exception as e:
        return f"ERROR: {e}"


def main():
    parser = argparse.ArgumentParser(description="Car listing scraper")
    parser.add_argument("--config", help="Path to searches.json")
    parser.add_argument("--url", help="Single URL to scrape")
    args = parser.parse_args()

    if args.url:
        urls = [{"url": args.url, "platform": "direct", "model": "unknown", "location": "unknown"}]
    elif args.config:
        with open(args.config) as f:
            searches = json.load(f)
        if not searches:
            print(json.dumps({"error": "No searches configured"}))
            sys.exit(0)
        urls = build_urls(searches)
    else:
        print(json.dumps({"error": "Provide --config or --url"}))
        sys.exit(1)

    if not urls:
        print(json.dumps({"error": "No URLs to crawl"}))
        sys.exit(0)

    # Import playwright here so the script can still show usage without it installed
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        print(json.dumps({"error": "playwright not installed. Run: pip install playwright && playwright install chromium"}))
        sys.exit(1)

    try:
        from playwright_stealth import stealth_sync
        has_stealth = True
    except ImportError:
        has_stealth = False

    results = []

    with sync_playwright() as p:
        browser = p.chromium.launch(
            headless=True,
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

        for entry in urls:
            url = entry["url"]
            content = crawl_page(page, url)
            results.append({
                "platform": entry["platform"],
                "model": entry["model"],
                "location": entry["location"],
                "url": url,
                "budget_min": entry.get("budget_min"),
                "budget_max": entry.get("budget_max"),
                "currency": entry.get("currency"),
                "content": content,
            })
            # Small delay between requests to be polite
            time.sleep(1)

        browser.close()

    print(json.dumps(results, ensure_ascii=False))


if __name__ == "__main__":
    main()
