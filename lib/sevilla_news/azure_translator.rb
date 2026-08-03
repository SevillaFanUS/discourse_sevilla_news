# frozen_string_literal: true

require "net/http"
require "json"

module ::SevillaNews
  # Thin wrapper around the Azure AI Translator REST API (v3).
  #
  # Free F0 tier: 2,000,000 characters/month, resets monthly. Unlike
  # DeepL's current free options (50k/month on the consumer product, or a
  # 1M-characters-total-ever free tier on the API), this comfortably
  # covers a daily digest indefinitely, and it fails closed (403/429)
  # rather than silently billing past quota.
  module AzureTranslator
    ENDPOINT = "https://api.cognitive.microsofttranslator.com/translate"

    def self.translate(text, source_lang: "es", target_lang: "en")
      return text if text.blank?

      api_key = SiteSetting.sevilla_news_azure_translator_key
      return text if api_key.blank?

      uri = URI(ENDPOINT)
      uri.query = URI.encode_www_form("api-version" => "3.0", "from" => source_lang, "to" => target_lang)

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 10
      http.read_timeout = 15

      request = Net::HTTP::Post.new(uri)
      request["Ocp-Apim-Subscription-Key"] = api_key
      request["Content-Type"] = "application/json; charset=UTF-8"

      # Regional (non-"Global") Translator resources require this header
      # in addition to the key, or Azure returns 401. Global resources
      # ignore it, so it's safe to always send when configured.
      region = SiteSetting.sevilla_news_azure_translator_region
      request["Ocp-Apim-Subscription-Region"] = region if region.present?

      request.body = [{ "Text" => text }].to_json

      response = http.request(request)
      unless response.is_a?(Net::HTTPSuccess)
        Rails.logger.warn(
          "[discourse-sevilla-news] Azure Translator failed (#{response.code}): #{response.body}",
        )
        return text
      end

      parsed = JSON.parse(response.body)
      parsed.dig(0, "translations", 0, "text") || text
    rescue => e
      Rails.logger.warn("[discourse-sevilla-news] Azure Translator error: #{e.message}")
      text
    end
  end
end
