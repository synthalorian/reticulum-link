import Config

config :reticulum_link,
  ecto_repos: []

config :reticulum_link, ReticulumLink.Web.Endpoint,
  url: [host: "localhost"],
  render_errors: [view: ReticulumLink.Web.ErrorHTML, accepts: ~w(html json)],
  pubsub_server: ReticulumLink.PubSub,
  live_view: [signing_salt: "reticulum_link_dev"]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
