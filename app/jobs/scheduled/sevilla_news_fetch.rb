# frozen_string_literal: true

require "cgi"

module ::Jobs
  class SevillaNewsFetch < ::Jobs::Scheduled
    # Checked frequently; the actual posting cadence is governed by
    # sevilla_news_interval_hours (see due_to_post?). The frequent check
    # just means a restart or a slow source can't cause a missed update.
    every 30.minutes

    DEFAULT_INTERVAL_HOURS = 3

    def execute(_args)
      return unless SiteSetting.sevilla_news_enabled
      return if SiteSetting.sevilla_news_category_id.to_i <= 0

      now = Time.zone.now
      return unless due_to_post?(now)

      limit = SiteSetting.sevilla_news_articles_per_source
      articles = ::SevillaNews::Sources.fetch_all(limit_per_source: limit)
      return if articles.empty?

      posted_urls = PluginStore.get(::SevillaNews::PLUGIN_NAME, "posted_urls") || []
      new_articles = articles.reject { |a| posted_urls.include?(a.url) }

      # Nothing new since the last update — skip quietly rather than
      # posting an empty digest, and leave last_posted_at alone so the
      # next check (30 min later) tries again instead of waiting out
      # another full interval.
      return if new_articles.empty?

      enriched = build_enriched_articles(new_articles)
      return if enriched.empty?

      post_digest(enriched, now)

      updated_posted_urls = (posted_urls + new_articles.map(&:url)).last(500)
      PluginStore.set(::SevillaNews::PLUGIN_NAME, "posted_urls", updated_posted_urls)
      PluginStore.set(::SevillaNews::PLUGIN_NAME, "last_posted_at", now.iso8601)
    end

    private

    def interval_hours
      hours = SiteSetting.sevilla_news_interval_hours.to_i
      hours.positive? ? hours : DEFAULT_INTERVAL_HOURS
    end

    def due_to_post?(now)
      last_posted_at = PluginStore.get(::SevillaNews::PLUGIN_NAME, "last_posted_at")
      return true if last_posted_at.blank?

      Time.zone.parse(last_posted_at) <= now - interval_hours.hours
    rescue ArgumentError, TypeError
      # Unparseable stored value (e.g. left over from an older version) —
      # treat as "never posted" rather than blocking forever.
      true
    end

    # Longest headline we'll splice into a topic title, before the
    # " — Sevilla FC news, <date>" suffix is appended.
    MAX_HEADLINE_IN_TITLE = 90

    def post_digest(enriched, now)
      raw = build_post_body(enriched, now)
      category_id = SiteSetting.sevilla_news_category_id.to_i

      topic_id = SiteSetting.sevilla_news_new_topic_per_update ? nil : todays_topic_id(now)

      if topic_id
        PostCreator.create!(
          Discourse.system_user,
          topic_id: topic_id,
          raw: raw,
          skip_validations: true,
        )
      else
        post =
          PostCreator.create!(
            Discourse.system_user,
            title: topic_title(now, enriched),
            raw: raw,
            category: category_id,
            skip_validations: true,
          )

        unless SiteSetting.sevilla_news_new_topic_per_update
          PluginStore.set(
            ::SevillaNews::PLUGIN_NAME,
            "current_topic",
            { "date" => now.to_date.to_s, "topic_id" => post.topic_id },
          )
        end
      end
    end

    # A title like "Sevilla FC News — August 10, 2026" is invisible to
    # anyone searching for the actual story, so lead with the day's top
    # headline and keep the date for uniqueness:
    #
    #   Fran González signs through 2031 — Sevilla FC news, Aug 10, 2026
    #
    # Only the first post of the day sets the title; later updates append
    # as replies and deliberately leave it alone rather than churning it
    # every three hours.
    def topic_title(now, enriched = nil)
      return generic_title(now) unless SiteSetting.sevilla_news_headline_in_title

      lead = lead_headline(enriched)
      return generic_title(now) if lead.blank?

      "#{lead} — Sevilla FC news, #{now.strftime("%b %-d, %Y")}"
    end

    def generic_title(now)
      if SiteSetting.sevilla_news_new_topic_per_update
        "Sevilla FC News — #{now.strftime("%B %-d, %Y, %-I:%M %p")}"
      else
        "Sevilla FC News — #{now.strftime("%B %-d, %Y")}"
      end
    end

    def lead_headline(enriched)
      headline = enriched&.first&.dig(:translated_title).to_s.strip
      return nil if headline.length < 10

      truncate_on_word(headline, MAX_HEADLINE_IN_TITLE)
    end

    def truncate_on_word(text, limit)
      return text if text.length <= limit

      cut = text[0...limit]
      boundary = cut.rindex(" ")
      cut = cut[0...boundary] if boundary
      "#{cut.sub(/[[:punct:]]+\z/, "")}…"
    end

    # The topic we started earlier today, if there is one and it still
    # exists (it may have been deleted by a moderator, in which case we
    # start a fresh one rather than erroring).
    def todays_topic_id(now)
      current = PluginStore.get(::SevillaNews::PLUGIN_NAME, "current_topic")
      return nil unless current.is_a?(Hash)
      return nil unless current["date"] == now.to_date.to_s

      topic_id = current["topic_id"]
      return nil if topic_id.blank?

      Topic.where(id: topic_id, deleted_at: nil).exists? ? topic_id : nil
    end

    def build_enriched_articles(new_articles)
      new_articles.filter_map do |article|
        # RSS sources already carry an excerpt from their feed; the two
        # scraped HTML sources need a separate fetch for the article's own
        # meta description.
        excerpt = article.excerpt.presence || ::SevillaNews::Sources.meta_description(article.url)

        # English-language sources (The Guardian, Football España) skip
        # translation entirely rather than round-tripping already-English
        # text through the API.
        if article.source_lang == "en"
          translated_title = article.title
          translated_excerpt = excerpt
        else
          translated_title = ::SevillaNews::AzureTranslator.translate(article.title)
          translated_excerpt = excerpt.present? ? ::SevillaNews::AzureTranslator.translate(excerpt) : nil
        end

        { article: article, translated_title: translated_title, translated_excerpt: translated_excerpt }
      rescue => e
        Rails.logger.warn("[discourse-sevilla-news] failed to enrich #{article.url}: #{e.message}")
        nil
      end
    end

    def build_post_body(enriched, now)
      by_source = enriched.group_by { |item| item[:article].source }

      sections =
        by_source.map do |source, items|
          lines =
            items.map do |item|
              # Raw <a target="_blank"> rather than markdown [text](url) so
              # these links always open in a new tab regardless of a
              # reader's own "open external links in new tab" preference —
              # Discourse's sanitizer explicitly allows target="_blank" and
              # adds rel="noopener" itself.
              title = CGI.escapeHTML(item[:translated_title])
              url = CGI.escapeHTML(item[:article].url)
              line = "- **<a href=\"#{url}\" target=\"_blank\" rel=\"noopener noreferrer\">#{title}</a>**"
              line += "\n  #{item[:translated_excerpt]}" if item[:translated_excerpt].present?
              line
            end

          "### #{source}\n\n#{lines.join("\n")}"
        end

      <<~MARKDOWN
        *Sevilla FC news update — #{now.strftime("%B %-d, %Y at %-I:%M %p")}. Headlines and short excerpts, translated from Spanish where needed, with links back to the original articles.*

        #{sections.join("\n\n")}
      MARKDOWN
    end
  end
end
