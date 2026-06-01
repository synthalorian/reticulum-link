import Config

# Raspberry Pi 4 target configuration

config :reticulum_link, ReticulumLink.Web.Endpoint,
  url: [host: "reticulum-link.local"],
  http: [port: 80]

# Nerves runtime configuration
config :nerves, :firmware, fwup_conf: "config/rpi4-fwup.conf"

# VintageNet networking
config :vintage_net,
  config: [
    {"usb0", %{type: VintageNetDirect}},
    {"eth0",
     %{
       type: VintageNetEthernet,
       ipv4: %{method: :dhcp}
     }},
    {"wlan0",
     %{
       type: VintageNetWiFi,
       vintage_net_wifi: %{
         networks: [
           %{
             key_mgmt: :wpa_psk,
             ssid: System.get_env("WIFI_SSID", ""),
             psk: System.get_env("WIFI_PSK", "")
           }
         ]
       },
       ipv4: %{method: :dhcp}
     }}
  ]

# Enable SSH for firmware updates
config :nerves_ssh,
  authorized_keys: [
    File.read!(Path.join(System.user_home!(), ".ssh/id_rsa.pub"))
  ]

# Logger: use RingLogger for circular log buffer on embedded
config :logger, backends: [RingLogger]

config :ring_logger,
  max_size: 1024,
  format: "$time $metadata[$level] $message\n"

# Disable code reloading in production firmware
config :phoenix, :code_reloader, false
