defmodule ReticulumLink.Web.MetricsController do
  @moduledoc """
  GET /metrics — Prometheus-compatible metrics endpoint.

  Renders the `Telemetry.Metrics` structs from `ReticulumLink.Telemetry.metrics/0`
  in Prometheus text exposition format. Counter values and last-value gauges are
  read from the ETS table maintained by `ReticulumLink.Telemetry`, which is
  populated by a `:telemetry` handler attached at application startup.
  """
  use Phoenix.Controller, formats: [:text]

  alias ReticulumLink.Telemetry

  # Note: fully-qualified — a bare `Telemetry.Metrics` alias would resolve
  # against the `ReticulumLink.Telemetry` alias above.
  alias Elixir.Telemetry.Metrics, as: TMetrics

  def index(conn, _params) do
    lines =
      Telemetry.metrics()
      |> Enum.flat_map(&format_metric/1)

    text_response(conn, Enum.join(lines, "\n") <> "\n")
  end

  defp format_metric(%{__struct__: struct, name: name, event_name: event})
       when struct in [TMetrics.Counter, TMetrics.Sum] do
    [
      "# HELP #{metric_name(name)} counter",
      "# TYPE #{metric_name(name)} counter",
      "#{metric_name(name)} #{lookup({event, :counter})}"
    ]
  end

  defp format_metric(%{__struct__: struct, name: name, event_name: event})
       when struct in [TMetrics.LastValue, TMetrics.Gauge] do
    [
      "# HELP #{metric_name(name)} gauge",
      "# TYPE #{metric_name(name)} gauge",
      "#{metric_name(name)} #{lookup({event, :last_value})}"
    ]
  end

  defp format_metric(_metric), do: []

  # Telemetry.Metrics names are atom lists, e.g.
  # [:reticulum_link, :link, :created, :count] → "reticulum_link_link_created_count"
  defp metric_name(name) when is_list(name) do
    Enum.map_join(name, "_", &Atom.to_string/1)
  end

  defp metric_name(name) when is_binary(name) do
    name |> String.replace(".", "_") |> String.replace(" ", "_")
  end

  defp lookup(key) do
    table = Telemetry.metrics_table()

    case :ets.whereis(table) do
      :undefined ->
        0

      _tid ->
        case :ets.lookup(table, key) do
          [{_key, value}] -> value
          [] -> 0
        end
    end
  end

  defp text_response(conn, body) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, body)
  end
end
