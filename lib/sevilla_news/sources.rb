# frozen_string_literal: true

require "net/http"

module ::SevillaNews
  # Scrapes headline + link (+ later, a short excerpt from the article's own
  # meta description) from each trusted source's Sevilla FC section. Sites
  # are plain server-rendered HTML, so a lightweight Net::HTTP + Nokogiri
  # scrape is enough — no headless browser needed.
  #
  # These are hand-picked structural selectors based on each site's current
  # markup (checked live). Like any scraper, they can break if a site
  # redesigns its listing page — if a source stops returning articles, the
  # selectors below are the first place to check.
  module Sources
    USER_AGENT = "Mozilla/5.0 (compatible; SevillaNewsBot/1.0; contact: forum.monchismen.com)"

    Article = Struct.new(:title, :url, :source, keyword_init: true)

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

    # Article's own <meta name="description"> — the publisher's own
    # one-sentence summary, the same text search engines and RSS readers
    # reuse. Used as a short excerpt instead of scraping article body text.
    def self.meta_description(article_url)
      html = fetch_html(article_url)
      return nil unless html

      doc = parse(html)
      node = doc.at_css('meta[name="description"]') || doc.at_css('meta[property="og:description"]')
      value = node && node["content"]
      value&.strip.presence
    end

    # ElDesmarque: <article> wraps an <a class="_cardTitleLink..."> whose
    # child is an <h2 class="_cardTitle...">. Class names are hashed
    # (Astro CSS modules) and can change on redeploy; the a > h2 structure
    # is the stable part.
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

    # AS.com: <article class="s..."> > ... > <h2 class="s_t"> whose own
    # child is the <a href="..."> carrying the headline text (anchor is
    # nested *inside* the heading here, not wrapping it).
    def self.as_com(limit:)
      base = "https://as.com/noticias/sevilla-futbol-club/"
      html = fetch_html(base)
      return [] unless html

      doc = parse(html)
      articles = []

      doc.css("article").each do |article_node|
        heading = article_node.at_css("h2, h3")
        next unless heading

        anchor = heading.at_css("a[href]") || article_node.at_css("a[href]")
        next unless anchor

        title = heading.text.strip
        href = anchor["href"]
        next if title.length < 8 || href.blank?

        articles << Article.new(title: title, url: normalize_url(href, base), source: "AS")
        break if articles.size >= limit
      end

      articles.uniq(&:url)
    end

    # Estadio Deportivo: <article class="card"> contains
    # <p class="titular"><a class="enlace-oscuro">Title</a></p> — the
    # anchor's own text is the headline, no separate heading tag.
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
      [eldesmarque(limit: limit_per_source), as_com(limit: limit_per_source), estadio_deportivo(limit: limit_per_source)].flatten
    end
  end
end
