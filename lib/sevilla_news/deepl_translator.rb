# frozen_string_literal: true

require "net/http"
require "json"

module ::SevillaNews
  # Thin wrapper around the DeepL REST API. Auto-selects the free vs pro
  # endpoint based on the API key suffix (DeepL free keys end in ":fx"),
  # per DeepL's own documented convention.
  module DeeplTranslator
    def self.translate(text, source_lang: "ES", target_lang: "EN")
      return text if text.blank?

      api_key = SiteSetting.sevilla_news_deepl_api_key
      return text if api_key.blank?

      uri = URI(endpoint_for(api_key))
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 10
      http.read_timeout = 15

      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "DeepL-Auth-Key #{api_key}"
      request.set_form_data(
        "text" => text,
        "source_lang" => source_lang,
        "target_lang" => target_lang,
      )

      response = http.request(request)
      unless response.is_a?(Net::HTTPSuccess)
        Rails.logger.warn(
          "[discourse-sevilla-news] DeepL translate failed (#{response.code}): #{response.body}",
        )
        return text
      end

      parsed = JSON.parse(response.body)
      parsed.dig("translations", 0, "text") || text
    rescue => e
      Rails.logger.warn("[discourse-sevilla-news] DeepL translate error: #{e.message}")
      text
    end

    def self.endpoint_for(api_key)
      if api_key.end_with?(":fx")
        "https://api-free.deepl.com/v2/translate"
      else
        "https://api.deepl.com/v2/translate"
      end
    end
  end
end
