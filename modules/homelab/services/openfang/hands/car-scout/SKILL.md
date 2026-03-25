---
domain: automotive-market
version: "1.0"
sources:
  - "Market observation heuristics"
  - "Common used car valuation principles"
---

# Used Car Market Knowledge

## Platform Reference

### Hungary
| Platform | URL | Currency | Notes |
|----------|-----|----------|-------|
| Hasznaltauto | hasznaltauto.hu | HUF | Largest HU market, structured listings |
| JoFogas | jofogas.hu | HUF | Classifieds, more private sellers |
| Autonavigator | autonavigator.hu | HUF | Dealer-heavy |

### Brazil
| Platform | URL | Currency | Notes |
|----------|-----|----------|-------|
| OLX | olx.com.br | BRL | General classifieds, private + dealer |
| WebMotors | webmotors.com.br | BRL | Largest BR auto market, dealer-heavy |
| iCarros | icarros.com.br | BRL | Itau-owned, good filters |
| Mercado Livre | mercadolivre.com.br | BRL | Marketplace, mixed quality |
| Kavak | kavak.com.br | BRL | Certified used, fixed prices |

### Europe (General)
| Platform | URL | Currency | Notes |
|----------|-----|----------|-------|
| Mobile.de | mobile.de | EUR | Largest EU market (DE-based) |
| AutoScout24 | autoscout24.com | EUR | Pan-European |
| OLX Europe | olx.pt / olx.ro / olx.pl | Local | Country-specific OLX variants |

### United States
| Platform | URL | Currency | Notes |
|----------|-----|----------|-------|
| Craigslist | craigslist.org | USD | Regional, private sellers |
| Facebook Marketplace | facebook.com/marketplace | USD | Large volume, hard to scrape |
| AutoTrader | autotrader.com | USD | Dealer-heavy |
| CarGurus | cargurus.com | USD | Has deal ratings built in |

## Mileage Benchmarks

Average annual mileage by market:
- **Brazil**: ~12,000 km/year
- **Hungary/EU**: ~15,000 km/year
- **United States**: ~20,000 km/year (12,500 miles)

Classification:
- **Low mileage**: < 70% of expected for age
- **Average**: 70-130% of expected
- **High mileage**: > 130% of expected

Example: A 2018 car in Hungary (6 years old) with expected ~90,000 km
- < 63,000 km = low mileage (positive signal)
- 63,000 - 117,000 km = average
- > 117,000 km = high mileage (price should reflect this)

## Price Evaluation Heuristics

### Depreciation Curve (general)
- Year 1: -15% to -25% from new
- Year 2-3: -10% to -15% per year
- Year 4-6: -7% to -10% per year
- Year 7+: -3% to -7% per year, flattening

### Deal Indicators
- **15%+ below comparable listings** for same model/year/mileage range = strong deal signal
- **Private seller** pricing is typically 10-15% below dealer for same car
- **End of month** listings from dealers may be discounted (quota pressure)
- **Listings active 30+ days** often have negotiation room

### Overpriced Signals
- Dealer price at or above private-party value
- "Price on request" (usually means overpriced)
- Heavy emphasis on cosmetic mods (usually not reflected in resale)

## Red Flags (Negative Scoring)

### High Risk — Deduct 20+ points
- Price 40%+ below market with no explanation (potential scam, flood, salvage)
- Listing mentions: rebuilt title, salvage, flood, structural damage
- VIN not provided when asked
- Seller wants payment before viewing
- Stock photos instead of actual car photos

### Medium Risk — Deduct 10-15 points
- 3+ owners in short period
- Mileage inconsistent with age (too low can mean rollback)
- Listing text is copy-pasted or generic
- No service history mentioned
- Car located far from seller's stated location

### Low Risk — Deduct 5 points
- Minor cosmetic damage disclosed
- Missing one service record
- Aftermarket modifications (may affect insurance)

## Fuel Type Market Preferences

### Brazil
- **Flex (ethanol/petrol)**: standard, most common — neutral value
- **Diesel**: restricted to trucks/SUVs by law — premium if applicable
- **Electric/Hybrid**: growing but limited infrastructure outside major cities

### Hungary / Central Europe
- **Diesel**: traditionally valued for fuel economy, declining due to emissions zones
- **Petrol**: standard, good resale
- **LPG**: common retrofit, lower running costs, slight resale discount
- **Electric**: limited charging infra outside Budapest, lower demand in used market

### General EU
- **Diesel**: declining demand in Western EU cities (bans), still valued in rural/Eastern EU
- **Hybrid**: good resale, especially plug-in
- **Electric**: growing fast, best resale in DE/NL/NO

## Search Query Patterns by Platform

### Hasznaltauto.hu
- Structured search: `{make} {model} site:hasznaltauto.hu {city}`
- Listings have consistent URL patterns: `hasznaltauto.hu/szemelyauto/{make}/{model}/{id}`
- Prices in HUF, sometimes EUR for imported cars

### OLX Brazil
- Search: `{make} {model} site:olx.com.br {city}`
- URL pattern: `{state}.olx.com.br/autos-e-pecas/carros-vans-e-utilitarios/{id}`
- Prices in BRL, sometimes noted "preco negociavel"

### Mobile.de
- Search: `{make} {model} site:mobile.de {city}`
- Prices in EUR, well-structured listing pages
- Has "fair price" indicators on some listings

### WebMotors
- Search: `{make} {model} site:webmotors.com.br {city}`
- Dealer-heavy, prices tend to be higher than OLX
- Good structured data in listings

## Transmission Preferences

- **Brazil**: automatic increasingly preferred, especially in cities. Manual still common in budget segment
- **Hungary/EU**: manual is standard. Automatic is a premium feature, better resale on higher-end models
- **US**: automatic is overwhelmingly standard. Manual is niche (can be premium on sports cars)
