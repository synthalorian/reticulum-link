defmodule ReticulumLink.Web.MetricsController do
  @moduledoc """
  GET /metrics — Prometheus-compatible metrics endpoint.
  """
  use Phoenix.Controller, formats: [:text]

  alias ReticulumLink.Telemetry

  def index(conn, _params) do
    metrics = Telemetry.metrics()

    # Build simple Prometheus text format
    lines = Enum.flat_map(metrics, &format_metric/1)

    text_response(conn, Enum.join(lines, "\n"))
  end

  defp format_metric(%{__struct__: struct, name: name})
       when struct in [Telemetry.Metrics.Counter, Telemetry.Metrics.Sum] do
    event = event_name(name)
    value = get_counter_value(event)

    [
      "# HELP #{metric_name(name)} counter",
      "# TYPE #{metric_name(name)} counter",
      "#{metric_name(name)} #{value}"
    ]
  end

  defp format_metric(%{__struct__: struct, name: name})
       when struct in [Telemetry.Metrics.LastValue, Telemetry.Metrics.Gauge] do
    event = event_name(name)
    value = get_last_value(event)

    [
      "# HELP #{metric_name(name)} gauge",
      "# TYPE #{metric_name(name)} gauge",
      "#{metric_name(name)} #{value}"
    ]
  end

  defp format_metric(_), do: []

  defp metric_name(name) do
    name |> String.replace(".", "_") |> String.replace(" ", "_")
  end

  defp event_name(name) do
    name
    |> String.split(".")
    |> Enum.map(&String.to_atom/1)
    |> List.replace_at(0, :reticulum_link)
  end

  defp get_counter_value(event_name) do
    # Read from telemetry event table or return 0
    case :ets.info(:telemetry_event_table) do
      :undefined ->
        0

      _ ->
        case :ets.lookup(:telemetry_event_table, event_name) do
          [{_, count}] -> count
          [] -> 0
        end
    end
  end

  defp get_last_value(event_name) do
    case :ets.info(:telemetry_event_table) do
      :undefined ->
        0

      _ ->
        case :ets.lookup(:telemetry_event_table, {event_name, :last_value}) do
          [{_, value}] -> value
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
