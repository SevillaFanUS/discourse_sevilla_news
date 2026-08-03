# frozen_string_literal: true

require "net/http"

module ::SevillaNews
  # Gets headline + link (+ a short excerpt) from each trusted source's
  # Sevilla FC coverage. ElDesmarque and Estadio Deportivo are scraped from
  # plain server-rendered HTML (Net::HTTP + Nokogiri, no browser needed) —
  # neither offers a team-specific RSS feed. Everything else comes from RSS
  # feeds, which is simpler and more robust than scraping where it's
  # available: no CSS selectors to keep in sync with a site's markup, and
  # most feeds already include a short excerpt so no second per-article
  # fetch is needed.
  #
  # The HTML scrapers use hand-picked structural selectors based on each
  # site's current markup (checked live). Like any scraper, they can break
  # if a site redesigns its listing page — if a source stops returning
  # articles, the selectors below are the first place to check.
  module Sources
    USER_AGENT = "Mozilla/5.0 (compatible; SevillaNewsBot/1.0; contact: forum.monchismen.com)"

    # Longest excerpt we'll post. Most feeds already give a one-sentence
    # summary, but a few (The Guardian, Football España) put several
    # paragraphs of real article text in <description> — this caps things
    # at a search-engine-snippet length regardless of source, so a feed
    # changing its format never accidentally turns into full-article
    # reproduction.
    MAX_EXCERPT_LENGTH = 240

    # RSS sources confirmed live to (a) actually be scoped to Sevilla FC
    # and (b) not require a browser to fetch. AS.com is here rather than
    # being scraped because its main site sits behind DataDome bot
    # protection that 403s any non-browser request — its feed, served from
    # a separate feeds.as.com host, isn't gated the same way.
    RSS_SOURCES = [
      {
        name: "AS",
        url: "https://feeds.as.com/mrss-s/list/as/site/as.com/tag/sevilla_futbol_club_a",
        lang: "es",
      },
      { name: "Diario de Sevilla", url: "https://www.diariodesevilla.es/rss/sevillafc/", lang: "es" },
      { name: "Marca", url: "https://e00-marca.uecdn.es/rss/futbol/sevilla.xml", lang: "es" },
      { name: "The Guardian", url: "https://www.theguardian.com/football/sevilla/rss", lang: "en" },
      {
        name: "Football España",
        url: "https://www.football-espana.net/category/la-liga/sevilla/feed",
        lang: "en",
      },
    ].freeze

    # excerpt is populated directly for RSS sources (which already include
    # a description) or via a separate meta_description fetch for the
    # scraped HTML sources. source_lang is "en" for English-language
    # sources (skips translation in the job) and nil/"es" otherwise.
    Article = Struct.new(:title, :url, :source, :excerpt, :source_lang, keyword_init: true)

    def self.fetch_html(url)
      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 10
      http.read_timeout = 15

      request = Net::HTTP::Get.new(uri)
      request["User-Agent"] = USER_AGENT

      response = http.request(request)
      return nil unless response.is_a?(Net::HTTPSuccess)

      response.body
    rescue => e
      Rails.logger.warn("[discourse-sevilla-news] fetch failed for #{url}: #{e.message}")
      nil
    end

    def self.parse(html)
      Nokogiri::HTML5(html)
    rescue StandardError
      Nokogiri::HTML(html)
    end

    def self.normalize_url(href, base)
      return href if href.start_with?("http://", "https://")
      return "https:#{href}" if href.start_with?("//")

      URI.join(base, href).to_s
    rescue URI::Error
      href
    end

    # Strips any HTML markup a feed's <description> might contain (The
    # Guardian and Football España both wrap theirs in <p> tags with
    # inline links) and truncates to MAX_EXCERPT_LENGTH at a word
    # boundary.
    def self.clean_excerpt(raw)
      return nil if raw.blank?

      text = Nokogiri::HTML5.fragment(raw).text.strip
      return nil if text.blank?
      return text if text.length <= MAX_EXCERPT_LENGTH

      truncated = text[0...MAX_EXCERPT_LENGTH]
      truncated = truncated[0...truncated.rindex(" ")] if truncated.index(" ")
      "#{truncated}…"
    end

    # Article's own <meta name="description"> — the publisher's own
    # one-sentence summary, the same text search engines and RSS readers
    # reuse. Used as a short excerpt instead of scraping article body text.
    def self.meta_description(article_url)
      html = fetch_html(article_url)
      return nil unless html

      doc = parse(html)
      node = doc.at_css('meta[name="description"]') || doc.at_css('meta[property="og:description"]')
      value = node && node["content"]
      clean_excerpt(value)
    end

    # Generic RSS/MRSS reader used for every entry in RSS_SOURCES.
    def self.from_rss(name:, feed_url:, limit:, lang: "es")
      xml = fetch_html(feed_url)
      return [] unless xml

      doc = Nokogiri::XML(xml)
      doc.remove_namespaces!
      articles = []

      doc.css("item").each do |item|
        title = item.at_css("title")&.text&.strip
        link = item.at_css("link")&.text&.strip
        next if title.blank? || link.blank? || title.length < 8

        excerpt = clean_excerpt(item.at_css("description")&.text)

        articles << Article.new(title: title, url: link, source: name, excerpt: excerpt, source_lang: lang)
        break if articles.size >= limit
      end

      articles.uniq(&:url)
    end

    # ElDesmarque: <article> wraps an <a class="_cardTitleLink..."> whose
    # child is an <h2 class="_cardTitle...">. Class names are hashed
    # (Astro CSS modules) and can change on redeploy; the a > h2 structure
    # is the stable part. No team-specific RSS feed is available.
    def self.eldesmarque(limit:)
      base = "https://www.eldesmarque.com/futbol/sevilla-fc/"
      html = fetch_html(base)
      return [] unless html

      doc = parse(html)
      articles = []

      doc.css("article").each do |article_node|
        anchor = article_node.css("a").find { |a| a.at_css("h2, h3") }
        next unless anchor

        heading = anchor.at_css("h2, h3")
        title = heading.text.strip
        href = anchor["href"]
        next if title.length < 8 || href.blank?

        articles << Article.new(title: title, url: normalize_url(href, base), source: "ElDesmarque")
        break if articles.size >= limit
      end

      articles.uniq(&:url)
    end

    # Estadio Deportivo: <article class="card"> contains
    # <p class="titular"><a class="enlace-oscuro">Title</a></p> — the
    # anchor's own text is the headline, no separate heading tag. No
    # team-specific RSS feed is available (only a site-wide sitemap feed).
    def self.estadio_deportivo(limit:)
      base = "https://www.estadiodeportivo.com/futbol/sevilla-fc/"
      html = fetch_html(base)
      return [] unless html

      doc = parse(html)
      articles = []

      doc.css("article").each do |article_node|
        anchor = article_node.at_css("a.enlace-oscuro") || article_node.at_css("p.titular a")
        next unless anchor

        title = anchor.text.strip
        href = anchor["href"]
        next if title.length < 8 || href.blank?

        articles << Article.new(title: title, url: normalize_url(href, base), source: "Estadio Deportivo")
        break if articles.size >= limit
      end

      articles.uniq(&:url)
    end

    def self.fetch_all(limit_per_source:)
      html_sources = [eldesmarque(limit: limit_per_source), estadio_deportivo(limit: limit_per_source)]

      rss_sources =
        RSS_SOURCES.map do |cfg|
          from_rss(name: cfg[:name], feed_url: cfg[:url], limit: limit_per_source, lang: cfg[:lang])
        end

      (html_sources + rss_sources).flatten
    end
  end
end
