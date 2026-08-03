# discourse-sevilla-news

Posts one topic a day collecting the latest Sevilla FC headlines from
several trusted sources — headline + a short excerpt (never the full
article), translated to English via Azure AI Translator where needed,
with a link back to the original for the full story.

Sources:

- ElDesmarque — https://www.eldesmarque.com/futbol/sevilla-fc/ (scraped, Spanish)
- Estadio Deportivo — https://www.estadiodeportivo.com/futbol/sevilla-fc/ (scraped, Spanish)
- AS — RSS feed, Spanish
- Diario de Sevilla — RSS feed, Spanish
- Marca — RSS feed, Spanish
- The Guardian — RSS feed, English (no translation needed)
- Football España — RSS feed, English (no translation needed)

`sevillafc.es` (the club's own site) isn't included — its news list is
loaded client-side via JavaScript rather than plain server-rendered HTML
or an RSS feed, so pulling from it needs more work than the others. Can
be added in a follow-up if it turns out to be worth it.

## How it works

- A scheduled job (`SevillaNewsFetch`) runs every 30 minutes.
- It only actually posts once per calendar day, at or after
  `sevilla_news_post_hour` (server-local time) — the frequent check just
  makes sure a restart or slow site doesn't cause a missed day.
- Each run pulls the latest headlines from every source in
  `lib/sevilla_news/sources.rb` — RSS feeds where available (`RSS_SOURCES`),
  plus two scraped listing pages (ElDesmarque, Estadio Deportivo) for the
  sources that don't offer one — skips any URL already posted before
  (tracked in `PluginStore`, last 500 remembered), translates title +
  excerpt via Azure AI Translator for the Spanish sources (English sources
  are posted as-is), and posts one topic with everything grouped by
  source.
- Posted as the Discourse system user.

## Install

Same process as `discourse-laliga-sidebar` / `discourse-sevilla-fixtures`:

1. Push this plugin's code to its own GitHub repo (e.g.
   `SevillaFanUS/discourse-sevilla-news`).
2. In `app.yml`, add a `git clone` hook line for it alongside the others:
   ```yaml
   - exec:
       cd: $home/plugins
       cmd:
         - git clone https://github.com/SevillaFanUS/discourse-sevilla-news.git
   ```
3. `./launcher rebuild app` (this one's a real plugin, so it needs a
   rebuild — same as the La Liga sidebar plugin).

## Configure

Admin > Settings > search "sevilla_news":

- **sevilla_news_enabled** — on/off switch.
- **sevilla_news_category_id** — which category the daily topic posts to.
  **Required** — the job won't post until this is set.
- **sevilla_news_azure_translator_key** — your Azure AI Translator
  subscription key. Free F0 tier gives 2,000,000 characters/month
  (recurring, permanent — not a one-time bucket), far more than a daily
  headline digest needs. Create a "Translator" resource in the Azure
  Portal (free tier available in most regions), then copy Key 1 from the
  resource's "Keys and Endpoint" page. Leave blank to post the original
  Spanish text untranslated (English sources are unaffected either way).
- **sevilla_news_azure_translator_region** — the Azure region your
  Translator resource is deployed in (e.g. `eastus`), also on the "Keys
  and Endpoint" page. Only needed if you created a regional resource
  rather than a "Global" one — leave blank for Global resources.
- **sevilla_news_articles_per_source** — how many latest articles to pull
  per source per day (default 5). With 7 sources this can add up fast —
  5/source/day is ~35 articles/day at the ceiling, though in practice
  most days will have far fewer *new* ones once the posted-URL dedup
  kicks in.
- **sevilla_news_post_hour** — server-local hour (0–23) the digest posts
  at or after (default 8, i.e. 8am).

## Adding another source

RSS is the easy path — most news sites and blogs have a feed even when
it's not linked anywhere obvious (check `<link rel="alternate"
type="application/rss+xml">` in the page's `<head>`, or try
`/feed`, `/rss.xml`, or `/rss/<section>/` on the site). To add one, append
an entry to `RSS_SOURCES` in `lib/sevilla_news/sources.rb`:

```ruby
{ name: "Source Name", url: "https://example.com/feed", lang: "es" }
```

Use `lang: "en"` for English-language sources to skip translation. No
other code changes needed — `from_rss` handles parsing, excerpt cleanup,
and truncation generically for every feed in the list.

If a source doesn't have a feed, it needs a scraper method instead
(see `eldesmarque` or `estadio_deportivo` for the pattern), which takes
more work: inspecting the site's actual HTML structure for stable
selectors, handling relative URLs, and keeping it in sync if the site
redesigns.

## A note on excerpts and copyright

Every excerpt — whether from a feed's `<description>` or a scraped page's
`<meta name="description">` — is capped at 240 characters
(`Sources::MAX_EXCERPT_LENGTH`) and stripped of any HTML. This matters
because not every feed is well-behaved: most give a one-sentence summary,
but The Guardian and Football España both put several paragraphs of real
article text in `<description>`. The cap means the digest only ever shows
a short, search-snippet-length excerpt regardless of what a given source
puts in its feed — full article text (including `<content:encoded>`,
which several feeds also include) is deliberately never used.

## A note on the scrapers

ElDesmarque and Estadio Deportivo don't offer team-specific RSS feeds, so
this plugin reads their public listing pages directly and picks out
headline + link using each site's current HTML structure. If one of these
stops showing up in the daily digest, the most likely cause is a site
redesign changing its markup — the fix is updating the CSS selectors in
`lib/sevilla_news/sources.rb` for that one source; the other sources
aren't affected.

AS.com is a special case worth knowing about: its main site is behind
DataDome bot protection, which returns an HTTP 403 JS-challenge page to
any non-browser request (confirmed live). That's why it's read from its
RSS feed (a separate, unprotected `feeds.as.com` host) instead of being
scraped like ElDesmarque/Estadio Deportivo. If another source ever starts
returning nothing and you confirm via `curl` from the server that you're
getting a 403 or a suspiciously small response, this is the same class of
problem — check whether the site has an RSS feed on an unprotected host
before spending time on scraper selectors.
