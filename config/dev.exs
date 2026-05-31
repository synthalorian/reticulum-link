import Config

config :reticulum_link, ReticulumLink.Web.Endpoint,
  http: [port: 4000],
  debug_errors: true,
  code_reloader: true,
  check_origin: false

config :logger, level: :debug
