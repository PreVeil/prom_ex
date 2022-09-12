if Code.ensure_loaded?(Plug.Cowboy) do
  defmodule PromEx.Plugins.PlugCowboy do
    @moduledoc """
    This plugin captures HTTP request metrics emitted by Plug.Cowboy.

    This plugin exposes the following metric group:
    - `:plug_cowboy_http_event_metrics`

    ## Plugin options

    - `routers`: **Required** This is a list with the full module names of your Routers (e.g MyAppWeb.Router).
      Phoenix and Plug routers are supported. When the Phoenix dependency is present in your project, a list of Phoenix Routers is expected. Otherwise a list of Plug.Router modules must be provided
    - `event_prefix`: **Optional**, allows you to set the event prefix for the Telemetry events.
    - `metric_prefix`: This option is OPTIONAL and is used to override the default metric prefix of
    `[otp_app, :prom_ex, :plug_cowboy]`. If this changes you will also want to set `plug_cowboy_metric_prefix`
    in your `dashboard_assigns` to the snakecase version of your prefix, the default
    `plug_cowboy_metric_prefix` is `{otp_app}_prom_ex_plug_cowboy`.



    To use plugin in your application, add the following to your PromEx module:

    ```
    defmodule WebApp.PromEx do
      use PromEx, otp_app: :web_app

      @impl true
      def plugins do
        [
          ...
          {PromEx.Plugins.PlugCowboy, routers: [MyApp.Router]}
        ]
      end

      @impl true
      def dashboards do
        [
          ...
          {:prom_ex, "plug_cowboy.json"}
        ]
      end
    end
    ```

      @impl true
      def dashboards do
        [
          ...
          {:prom_ex, "plug_cowboy.json"}
        ]
      end
    end
    ```


    """

    use PromEx.Plugin

    require Logger

    @impl true
    def event_metrics(opts) do
      otp_app = Keyword.fetch!(opts, :otp_app)
      metric_prefix = [otp_app, :prom_ex]

      [
        http_events(metric_prefix, opts)
      ]
    end

    defp http_events(metric_prefix, opts) do
      # Shared configuration
      cowboy_stop_event = [:cowboy, :request, :stop]
      http_metrics_tags = [:status, :method, :path]

      allow_routes_fun = Keyword.get(opts , :allow_routes_fun, fn(_) -> true end)
      drop_routes_fun = Keyword.get(opts , :drop_routes_fun, fn(_) -> false end)

      routers =
        opts
        |> Keyword.fetch!(:routers)
        |> MapSet.new()

      Event.build(
        :plug_cowboy_http_event_metrics,
        [
          # Capture request duration information
          distribution(
            metric_prefix ++ [:http, :request, :duration, :milliseconds],
            event_name: cowboy_stop_event,
            measurement: :duration,
            description: "The time it takes for the application to process HTTP requests.",
            reporter_options: [
              buckets: [10, 100, 500, 1_000, 5_000, 10_000, 30_000]
            ],
            drop: drop_route?(allow_routes_fun),
            tag_values: &get_tags(&1, routers),
            tags: http_metrics_tags,
            unit: {:native, :millisecond}
          ),
          distribution(
            metric_prefix ++ [:http, :response, :duration, :milliseconds],
            event_name: cowboy_stop_event,
            measurement: :resp_duration,
            description: "The time it takes for the application to send the HTTP response.",
            reporter_options: [
              buckets: [10, 100, 500, 1_000, 5_000, 10_000, 30_000]
            ],
            drop: drop_route?(allow_routes_fun),
            tag_values: &get_tags(&1, routers),
            tags: http_metrics_tags,
            unit: {:native, :millisecond}
          ),
          distribution(
            metric_prefix ++ [:http, :request_body, :duration, :milliseconds],
            event_name: cowboy_stop_event,
            measurement: :req_body_duration,
            description: "The time it takes for the application to receive the HTTP request body.",
            reporter_options: [
              buckets: [10, 100, 500, 1_000, 5_000, 10_000, 30_000]
            ],
            drop: drop_route?(allow_routes_fun),
            tag_values: &get_tags(&1, routers),
            tags: http_metrics_tags,
            unit: {:native, :millisecond}
          ),

          # Capture response payload size information
          distribution(
            metric_prefix ++ [:http, :response, :size, :bytes],
            event_name: cowboy_stop_event,
            measurement: :resp_body_length,
            description: "The size of the HTTP response payload.",
            reporter_options: [
              buckets: [64, 512, 4_096, 65_536, 262_144, 1_048_576, 4_194_304, 16_777_216]
            ],
            drop: drop_route?(allow_routes_fun),
            tag_values: &get_tags(&1, routers),
            tags: http_metrics_tags,
            unit: :byte
          ),

          # Capture the number of requests that have been serviced
          counter(
            metric_prefix ++ [:http, :requests, :total],
            event_name: cowboy_stop_event,
            description: "The number of requests that have been serviced.",
            drop: drop_route?(allow_routes_fun),
            tag_values: &get_tags(&1, routers),
            tags: http_metrics_tags
          ),

          # Capture the number of requests that have been serviced
          counter(
            metric_prefix ++ [:http, :invalid, :requests, :total],
            event_name: cowboy_stop_event,
            description: "The number of invalid requests that have been serviced.",
            drop: drop_bad_route?(drop_routes_fun),
            tag_values: &get_bad_tags(&1),
            tags: http_metrics_tags
          )
        ]
      )
    end

    defp get_tags(%{resp_status: resp_status, req: %{method: method} = req}, routers) do
      case get_http_status(resp_status) do
        status when is_binary(status) ->
          %{
            status: status,
            method: method,
            path: maybe_get_parametrized_path(req, routers)
          }

        :undefined ->
          %{
            status: :undefined,
            method: method,
            path: maybe_get_parametrized_path(req, routers)
          }

        nil ->
          Logger.warn("Cowboy failed to provide valid response status #{inspect(resp_status)}")
          %{}
      end
    end

    defp get_bad_tags(_) do
     %{
        status: "404",
        method: "XXX",
        path: "invalid"
      }
    end

    defp maybe_get_parametrized_path(req, _routers) do
      String.replace(req.path, "mailboxes", "mboxes")
      |> String.replace("messages", "msgs")
      |> String.split("/", trim: true) 
      |> Enum.filter(fn s -> len = String.length(s); len > 2 && len < 15 end) 
      |> Enum.map_join("/", &(&1))
    end

    defp get_http_status(resp_status) when is_integer(resp_status) do
      to_string(resp_status)
    end

    defp get_http_status(resp_status) when is_bitstring(resp_status) do
      [code | _rest] = String.split(resp_status)
      code
    end

    defp get_http_status(nil) do
      nil
    end

    defp get_http_status(_resp_status) do
      :undefined
    end

    defp drop_route?(allow_routes_fun) do
      fn
        %{req: %{}} = rsp_map ->
          not allow_routes_fun.(rsp_map);

        _meta ->
          false
      end
    end

    defp drop_bad_route?(drop_routes_fun) do
      fn
        %{req: %{}} = rsp_map ->
          drop_routes_fun.(rsp_map);

        _meta ->
          true
      end
    end

  end
else
  defmodule PromEx.Plugins.PlugCowboy do
    @moduledoc false
    use PromEx.Plugin

    @impl true
    def event_metrics(_opts) do
      PromEx.Plugin.no_dep_raise(__MODULE__, "Plug.Cowboy")
    end
  end
end
