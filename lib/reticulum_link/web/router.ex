defmodule ReticulumLink.Web.Router do
  @moduledoc """
  REST API router for Reticulum Link.

  Routes:
  - GET  /api/status   — Node status, uptime, peer count
  - GET  /api/peers    — List known peers
  - GET  /api/messages — List stored LXMF messages
  - POST /api/messages — Send a new LXMF message
  """

  use Phoenix.Router

  import Plug.Conn
  import Phoenix.Controller

  pipeline :api do
    plug :accepts, ["json"]
    plug ReticulumLink.Web.Plugs.Auth
  end

  scope "/api", ReticulumLink.Web do
    pipe_through :api

    get "/status", StatusController, :index
    get "/peers", PeersController, :index
    get "/messages", MessagesController, :index
    post "/messages", MessagesController, :create
  end
end
