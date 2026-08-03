# discourse-sevilla-news

Posts one topic a day collecting the latest Sevilla FC headlines from three
trusted Spanish sources — headline + a short excerpt (the publisher's own
meta-description, not the full article), translated to English via DeepL,
with a link back to the original for the full story.

Sources (v1):

- ElDesmarque — https://www.eldesmarque.com/futbol/sevilla-fc/
- AS — https://as.com/noticias/sevilla-futbol-club/
- Estadio Deportivo — https://www.estadiodeportivo.com/futbol/sevilla-fc/

`sevillafc.es` (the club's own site) isn't included yet — its news list is
loaded client-side via JavaScript rather than plain server-rendered HTML, so
scraping it needs more work. Can be added in a follow-up.

## How it works

- A scheduled job (`SevillaNewsFetch`) runs every 30 minutes.
- It only actually posts once per calendar day, at or after
  `sevilla_news_post_hour` (server-local time) — the frequent check just
  makes sure a restart or slow site doesn't cause a missed day.
- Each run scrapes each source's listing page for the latest headlines
  (Net::HTTP + Nokogiri, no browser needed), skips any URL already posted
  before (tracked in `PluginStore`, last 500 remembered), fetches each new
  article's own `<meta name="description">` as a short excerpt, translates
  title + excerpt via DeepL, and posts one topic with everything grouped by
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
- **sevilla_news_deepl_api_key** — your DeepL API key. Get a free one at
  https://www.deepl.com/pro-api (500,000 characters/month free tier, more
  than enough for daily headlines). Leave blank to post the original
  Spanish text untranslated.
- **sevilla_news_articles_per_source** — how many latest articles to pull
  per source per day (default 5).
- **sevilla_news_post_hour** — server-local hour (0–23) the digest posts
  at or after (default 8, i.e. 8am).

## A note on the scrapers

These sites don't offer RSS feeds, so this plugin reads their public
listing pages directly and picks out headline + link using each site's
current HTML structure. If a source ever stops showing up in the daily
digest, the most likely cause is a site redesign changing its markup —
the fix is updating the CSS selectors in `lib/sevilla_news/sources.rb`
for that one source; the other sources aren't affected.
