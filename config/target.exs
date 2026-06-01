import Config

# Target-specific configuration loader
# This file is imported when MIX_TARGET is set (not :host)

target = Mix.target()

# Load target-specific config if it exists
target_config = Path.join(__DIR__, "target/#{target}.exs")

if File.exists?(target_config) do
  import_config target_config
else
  # Default embedded config for unknown targets
  config :logger, backends: [RingLogger]
  config :phoenix, :code_reloader, false
end
