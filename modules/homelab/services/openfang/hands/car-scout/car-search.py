#!/usr/bin/env python3
"""Car listing scraper — renders JS-heavy pages with Playwright and extracts visible text.

Usage:
    car-search.py --config /persist/openfang/car-scout/searches.json
    car-search.py --config /persist/openfang/car-scout/searches.json --pages 3
    car-search.py --url "https://www.webmotors.com.br/carros-usados/pa-belem/honda/civic"

Returns JSON array of {platform, model, url, page, content} for each crawled page.
The Hand (LLM) parses the text content to extract individual listings.
"""
import argparse
import json
import sys
import os
import time

# --- Pagination patterns per platform ---
# Each returns a list of URLs for pages 1..N

def webmotors_pages(base_url, num_pages):
    """WebMotors: ?page=1, ?page=2, ..."""
    urls = [base_url]  # page 1 is the base URL
    for p in range(2, num_pages + 1):
        sep = "&" if "?" in base_url else "?"
        urls.append(f"{base_url}{sep}page={p}")
    return urls


def olx_pages(base_url, num_pages):
    """OLX: ?o=1, ?o=2, ..."""
    urls = [base_url]
    for p in range(2, num_pages + 1):
        sep = "&" if "?" in base_url else "?"
        urls.append(f"{base_url}{sep}o={p}")
    return urls


def mobiauto_pages(base_url, num_pages):
    """Mobiauto: ?page=1, ?page=2, ..."""
    urls = [base_url]
    for p in range(2, num_pages + 1):
        sep = "&" if "?" in base_url else "?"
        urls.append(f"{base_url}{sep}page={p}")
    return urls


def generic_pages(base_url, num_pages):
    """Fallback: ?page=1, ?page=2, ..."""
    urls = [base_url]
    for p in range(2, num_pages + 1):
        sep = "&" if "?" in base_url else "?"
        urls.append(f"{base_url}{sep}page={p}")
    return urls


PLATFORM_PAGINATORS = {
    "webmotors.com.br": webmotors_pages,
    "olx.com.br": olx_pages,
    "mobiauto.com.br": mobiauto_pages,
}


# --- Platform URL builders ---

def webmotors_url(model, location, state="pa", **kw):
    city = location.lower().replace(" ", "-").replace("ã", "a").replace("é", "e")
    make = guess_make(model)
    return f"https://www.webmotors.com.br/carros-usados/{state}-{city}/{make}/{model}"


def olx_url(model, location, state="pa", **kw):
    city = location.lower().replace(" ", "-").replace("ã", "a").replace("é", "e")
    make = guess_make(model)
    return f"https://www.olx.com.br/autos-e-pecas/carros-vans-e-utilitarios/{make}/{model}/estado-{state}/regiao-de-{city}"


def mobiauto_url(model, location, state="pa", **kw):
    city = location.lower().replace(" ", "-").replace("ã", "a").replace("é", "e")
    make = guess_make(model)
    return f"https://www.mobiauto.com.br/comprar/carros-usados/{state}-{city}/{make}/{model}"


def generic_url(platform, model, location, **kw):
    make = guess_make(model)
    return f"https://www.{platform}/search?q={make}+{model}+{location}"


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


def build_urls(searches, num_pages=1):
    """Build all URLs from the searches config, with pagination."""
    urls = []
    for search in searches:
        location = search.get("location", "")
        state = search.get("state", "") or guess_state(location)
        platforms = search.get("platforms", [])
        models = search.get("models", [])

        for platform in platforms:
            builder = PLATFORM_BUILDERS.get(platform, None)
            paginator = PLATFORM_PAGINATORS.get(platform, generic_pages)

            for model in models:
                if builder:
                    base_url = builder(model=model, location=location, state=state)
                else:
                    base_url = generic_url(platform=platform, model=model, location=location)

                page_urls = paginator(base_url, num_pages)

                for page_num, url in enumerate(page_urls, 1):
                    urls.append({
                        "url": url,
                        "platform": platform,
                        "model": model,
                        "location": location,
                        "page": page_num,
                        "budget_min": search.get("budget_min"),
                        "budget_max": search.get("budget_max"),
                        "currency": search.get("currency", "BRL"),
                    })
    return urls


def crawl_page(page, url, timeout=30000):
    """Navigate to URL, wait for JS, return visible text."""
    try:
        page.goto(url, wait_until="networkidle", timeout=timeout)
        page.wait_for_timeout(2000)
        text = page.inner_text("body")
        return text[:30000]
    except Exception as e:
        return f"ERROR: {e}"


def main():
    parser = argparse.ArgumentParser(description="Car listing scraper")
    parser.add_argument("--config", help="Path to searches.json")
    parser.add_argument("--url", help="Single URL to scrape")
    parser.add_argument("--pages", type=int, default=2, help="Number of pages per search (default: 2)")
    args = parser.parse_args()

    if args.url:
        urls = [{"url": args.url, "platform": "direct", "model": "unknown", "location": "unknown", "page": 1}]
    elif args.config:
        with open(args.config) as f:
            searches = json.load(f)
        if not searches:
            print(json.dumps({"error": "No searches configured"}))
            sys.exit(0)
        urls = build_urls(searches, num_pages=args.pages)
    else:
        print(json.dumps({"error": "Provide --config or --url"}))
        sys.exit(1)

    if not urls:
        print(json.dumps({"error": "No URLs to crawl"}))
        sys.exit(0)

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

        prev_content = None
        for entry in urls:
            url = entry["url"]
            content = crawl_page(page, url)

            # Stop paginating if content is the same as previous page (no more results)
            if content == prev_content:
                continue
            prev_content = content

            results.append({
                "platform": entry["platform"],
                "model": entry["model"],
                "location": entry["location"],
                "page": entry["page"],
                "url": url,
                "budget_min": entry.get("budget_min"),
                "budget_max": entry.get("budget_max"),
                "currency": entry.get("currency"),
                "content": content,
            })
            time.sleep(1)

        browser.close()

    print(json.dumps(results, ensure_ascii=False))


if __name__ == "__main__":
    main()
