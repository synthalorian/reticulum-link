defmodule ReticulumLink.Web.Endpoint do
  @moduledoc false
  use Phoenix.Endpoint, otp_app: :reticulum_link

  socket "/socket", ReticulumLink.Web.UserSocket,
    websocket: true,
    longpoll: false

  plug ReticulumLink.Web.Router

  def init(_opts) do
    :ok
  end
end
