defmodule ReticulumLink do
  @moduledoc """
  Reticulum Link — High-performance Reticulum transport node and LXMF relay.

  Built on the BEAM VM for fault-tolerant management of thousands of
  concurrent encrypted links. Serves as a network backbone node,
  message propagation relay, and service gateway.
  """

  @version Mix.Project.config()[:version]

  def version, do: @version
end
