# frozen_string_literal: true

module ::Jobs
  class SevillaNewsFetch < ::Jobs::Scheduled
    every 30.minutes

    def execute(_args)
      return unless SiteSetting.sevilla_news_enabled
      return if SiteSetting.sevilla_news_category_id.to_i <= 0

      now = Time.zone.now
      return if now.hour < SiteSetting.sevilla_news_post_hour

      today_key = now.to_date.to_s
      last_posted = PluginStore.get(::SevillaNews::PLUGIN_NAME, "last_posted_date")
      return if last_posted == today_key

      limit = SiteSetting.sevilla_news_articles_per_source
      articles = ::SevillaNews::Sources.fetch_all(limit_per_source: limit)
      return if articles.empty?

      posted_urls = PluginStore.get(::SevillaNews::PLUGIN_NAME, "posted_urls") || []
      new_articles = articles.reject { |a| posted_urls.include?(a.url) }
      return if new_articles.empty?

      enriched = build_enriched_articles(new_articles)
      return if enriched.empty?

      title = "Sevilla FC News — #{now.strftime("%B %-d, %Y")}"
      raw = build_post_body(enriched, now)

      PostCreator.create!(
        Discourse.system_user,
        title: title,
        raw: raw,
        category: SiteSetting.sevilla_news_category_id.to_i,
        skip_validations: true,
      )

      updated_posted_urls = (posted_urls + new_articles.map(&:url)).last(500)
      PluginStore.set(::SevillaNews::PLUGIN_NAME, "posted_urls", updated_posted_urls)
      PluginStore.set(::SevillaNews::PLUGIN_NAME, "last_posted_date", today_key)
    end

    private

    def build_enriched_articles(new_articles)
      new_articles.filter_map do |article|
        excerpt = ::SevillaNews::Sources.meta_description(article.url)
        translated_title = ::SevillaNews::DeeplTranslator.translate(article.title)
        translated_excerpt = excerpt.present? ? ::SevillaNews::DeeplTranslator.translate(excerpt) : nil

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
              line = "- **[#{item[:translated_title]}](#{item[:article].url})**"
              line += "\n  #{item[:translated_excerpt]}" if item[:translated_excerpt].present?
              line
            end

          "### #{source}\n\n#{lines.join("\n")}"
        end

      <<~MARKDOWN
        Daily Sevilla FC news roundup — #{now.strftime("%B %-d, %Y")}. Headlines and short excerpts, translated from Spanish where needed, with links back to the original articles.

        #{sections.join("\n\n")}
      MARKDOWN
    end
  end
end
