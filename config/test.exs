import Config

# Configure logger for tests
config :logger, level: :warning

# Disable web endpoint in tests (we only test crypto)
config :reticulum_link, ReticulumLink.Web.Endpoint,
  http: [port: 0],
  secret_key_base: "test"
