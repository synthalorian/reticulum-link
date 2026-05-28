import Config

config :reticulum_link, ReticulumLink.Web.Endpoint,
  http: [port: {:system, "PORT", "4000"}],
  cache_static_manifest: "priv/static/cache_manifest.json",
  server: true

config :logger, level: :info
