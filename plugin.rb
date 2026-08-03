# frozen_string_literal: true

# name: discourse-sevilla-news
# about: Posts a daily topic collecting the latest Sevilla FC news headlines (with short excerpts) from trusted Spanish sources, translated to English via DeepL, with links back to the originals.
# version: 0.1.0
# authors: Chris Lail
# url: https://forum.monchismen.com

enabled_site_setting :sevilla_news_enabled

module ::SevillaNews
  PLUGIN_NAME = "discourse-sevilla-news"
end

after_initialize do
  require_relative "lib/sevilla_news/deepl_translator"
  require_relative "lib/sevilla_news/sources"
  require_relative "app/jobs/scheduled/sevilla_news_fetch"
end
