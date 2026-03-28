#!/usr/bin/env bash
# Provision Miniflux with curated RSS feeds organized by category.
# Run once after Miniflux is up:
#   bash /etc/nixos/modules/homelab/services/miniflux/provision-feeds.sh
#
# Requires: MINIFLUX_URL, MINIFLUX_USER, MINIFLUX_PASS environment variables
# Or pass them as arguments: ./provision-feeds.sh https://news.demasi.dev admin password

set -euo pipefail

MINIFLUX_URL="${MINIFLUX_URL:-${1:-}}"
MINIFLUX_USER="${MINIFLUX_USER:-${2:-}}"
MINIFLUX_PASS="${MINIFLUX_PASS:-${3:-}}"

if [ -z "$MINIFLUX_URL" ] || [ -z "$MINIFLUX_USER" ] || [ -z "$MINIFLUX_PASS" ]; then
  echo "Usage: $0 <miniflux_url> <username> <password>"
  echo "  or set MINIFLUX_URL, MINIFLUX_USER, MINIFLUX_PASS env vars"
  exit 1
fi

API="$MINIFLUX_URL/v1"
AUTH="-u $MINIFLUX_USER:$MINIFLUX_PASS"

# Create a category, return its ID
create_category() {
  local title="$1"
  local existing
  existing=$(curl -s $AUTH "$API/categories" | jq -r ".[] | select(.title == \"$title\") | .id")
  if [ -n "$existing" ]; then
    echo "$existing"
    return
  fi
  curl -s $AUTH -X POST "$API/categories" \
    -H "Content-Type: application/json" \
    -d "{\"title\": \"$title\"}" | jq -r '.id'
}

# Add a feed to a category (skip if already exists)
add_feed() {
  local category_id="$1"
  local feed_url="$2"
  local result
  result=$(curl -s $AUTH -X POST "$API/feeds" \
    -H "Content-Type: application/json" \
    -d "{\"feed_url\": \"$feed_url\", \"category_id\": $category_id, \"crawler\": false}")

  local error
  error=$(echo "$result" | jq -r '.error_message // empty')
  if [ -n "$error" ]; then
    echo "  SKIP: $feed_url ($error)"
  else
    local title
    title=$(curl -s $AUTH "$API/feeds/$(echo "$result" | jq -r '.feed_id')" | jq -r '.title // "unknown"')
    echo "  OK: $title"
  fi
}

echo "=== Miniflux Feed Provisioning ==="
echo "Server: $MINIFLUX_URL"
echo ""

# --- World News ---
echo ">> World News"
CID=$(create_category "World News")
add_feed "$CID" "https://feeds.apnews.com/rss/apf-topnews"
add_feed "$CID" "https://feeds.bbci.co.uk/news/world/rss.xml"
add_feed "$CID" "https://theconversation.com/global/articles.atom"
add_feed "$CID" "https://www.theguardian.com/world/rss"

# --- PT-BR News ---
echo ">> PT-BR News"
CID=$(create_category "PT-BR News")
add_feed "$CID" "https://agenciabrasil.ebc.com.br/rss/ultimasnoticias/feed.xml"
add_feed "$CID" "https://www.brasildefato.com.br/rss2.xml"
add_feed "$CID" "https://brazilian.report/feed/"

# --- Tech / SWE ---
echo ">> Tech / SWE"
CID=$(create_category "Tech / SWE")
add_feed "$CID" "https://news.ycombinator.com/rss"
add_feed "$CID" "https://lobste.rs/rss"
add_feed "$CID" "https://blog.pragmaticengineer.com/rss/"
add_feed "$CID" "https://jvns.ca/atom.xml"
add_feed "$CID" "https://drewdevault.com/blog/index.xml"
add_feed "$CID" "https://martinfowler.com/feed.atom"
add_feed "$CID" "https://danluu.com/atom.xml"
add_feed "$CID" "https://feeds.arstechnica.com/arstechnica/technology-lab"

# --- Nix / Linux / Infra ---
echo ">> Nix / Linux / Infra"
CID=$(create_category "Nix / Linux / Infra")
add_feed "$CID" "https://discourse.nixos.org/latest.rss"
add_feed "$CID" "https://lwn.net/headlines/rss"
add_feed "$CID" "https://www.brendangregg.com/blog/rss.xml"
add_feed "$CID" "https://xeiaso.net/blog.rss"
add_feed "$CID" "https://blog.jessfraz.com/index.xml"

# --- AI / LLMs ---
echo ">> AI / LLMs"
CID=$(create_category "AI / LLMs")
add_feed "$CID" "https://simonwillison.net/atom/everything/"
add_feed "$CID" "https://sebastianraschka.com/rss_feed.xml"
add_feed "$CID" "https://www.latent.space/feed"
add_feed "$CID" "https://lilianweng.github.io/index.xml"

# --- Startups / Business ---
echo ">> Startups / Business"
CID=$(create_category "Startups / Business")
add_feed "$CID" "https://paulgraham.com/rss.html"
add_feed "$CID" "https://stratechery.com/feed/"
add_feed "$CID" "https://www.lennysnewsletter.com/feed"
add_feed "$CID" "https://saastr.com/feed/"

# --- Finance / Markets ---
echo ">> Finance / Markets"
CID=$(create_category "Finance / Markets")
add_feed "$CID" "https://www.bloomberg.com/opinion/authors/ARbTQlRLRjE/matthew-s-levine.rss"
add_feed "$CID" "https://feeds.feedburner.com/CafeComEconomia"

# --- Science / Space ---
echo ">> Science / Space"
CID=$(create_category "Science / Space")
add_feed "$CID" "https://api.quantamagazine.org/feed/"
add_feed "$CID" "https://www.nature.com/nature.rss"
add_feed "$CID" "https://www.nasa.gov/feed/"
add_feed "$CID" "https://spacenews.com/feed/"

# --- Privacy / Security ---
echo ">> Privacy / Security"
CID=$(create_category "Privacy / Security")
add_feed "$CID" "https://krebsonsecurity.com/feed/"
add_feed "$CID" "https://www.schneier.com/feed/"
add_feed "$CID" "https://therecord.media/feed"
add_feed "$CID" "https://www.eff.org/rss/updates.xml"

# --- Football ---
echo ">> Football"
CID=$(create_category "Football")
add_feed "$CID" "https://ge.globo.com/rss/futebol/times/fluminense/"
add_feed "$CID" "https://www.reddit.com/r/futebol/.rss"
add_feed "$CID" "https://www.reddit.com/r/nense/.rss"
add_feed "$CID" "https://trivela.com.br/feed/"

echo ""
echo "=== Done! ==="
