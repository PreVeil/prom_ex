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

    - `duration_unit`: This is an OPTIONAL option and is a `Telemetry.Metrics.time_unit()`. It can be one of:
      `:second | :millisecond | :microsecond | :nanosecond`. It is `:millisecond` by default.

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

      drop_good_routes_fun = Keyword.get(opts , :drop_good_routes_fun, fn(_) -> false end)
      drop_bad_routes_fun = Keyword.get(opts , :drop_bad_routes_fun, fn(_) -> true end)
      path_formatter_fun = Keyword.get(opts , :path_formatter_fun, fn(%{req: %{path: path}}) -> path end)

      duration_unit = Keyword.get(opts, :duration_unit, :millisecond)
      duration_unit_plural = String.to_atom("#{duration_unit}s")

      Event.build(
        :plug_cowboy_http_event_metrics,
        [
          # Capture request duration information
          distribution(
            metric_prefix ++ [:http, :request, :duration, duration_unit_plural],
            event_name: cowboy_stop_event,
            measurement: :duration,
            description: "The time it takes for the application to process HTTP requests.",
            reporter_options: [
              buckets: [10, 100, 500, 1_000, 5_000, 10_000, 30_000]
            ],
            drop: drop_good_route?(drop_good_routes_fun),
            tag_values: &get_tags(&1, path_formatter_fun),
            tags: http_metrics_tags,
            unit: {:native, duration_unit}
          ),
          distribution(
            metric_prefix ++ [:http, :response, :duration, duration_unit_plural],
            event_name: cowboy_stop_event,
            measurement: :resp_duration,
            description: "The time it takes for the application to send the HTTP response.",
            reporter_options: [
              buckets: [10, 100, 500, 1_000, 5_000, 10_000, 30_000]
            ],
            drop: Process.get(:current_drop_good_route),
            tag_values: &get_tags(&1, :get),
            tags: http_metrics_tags,
            unit: {:native, duration_unit}
          ),
          distribution(
            metric_prefix ++ [:http, :request_body, :duration, duration_unit_plural],
            event_name: cowboy_stop_event,
            measurement: :req_body_duration,
            description: "The time it takes for the application to receive the HTTP request body.",
            reporter_options: [
              buckets: [10, 100, 500, 1_000, 5_000, 10_000, 30_000]
            ],
            drop: Process.get(:current_drop_good_route),
            tag_values: &get_tags(&1, :get),
            tags: http_metrics_tags,
            unit: {:native, duration_unit}
          ),

          # Capture request payload size information
          distribution(
            metric_prefix ++ [:http, :request, :size, :bytes],
            event_name: cowboy_stop_event,
            measurement: :req_body_length,
            description: "The size of the HTTP request payload.",
            reporter_options: [
              buckets: [64, 512, 4_096, 65_536, 262_144, 1_048_576, 4_194_304, 16_777_216]
            ],
            drop: Process.get(:current_drop_good_route),
            tag_values: &get_tags(&1, :get),
            tags: http_metrics_tags,
            unit: :byte
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
            drop: Process.get(:current_drop_good_route),
            tag_values: &get_tags(&1, :get),
            tags: http_metrics_tags,
            unit: :byte
          ),

          # Capture the number of requests that have been serviced
          counter(
            metric_prefix ++ [:http, :requests, :total],
            event_name: cowboy_stop_event,
            description: "The number of requests that have been serviced.",
            drop: Process.delete(:current_drop_good_route),
            tag_values: &get_tags(&1, :get_delete),
            tags: http_metrics_tags
          ),

          # Capture the number of invalid requests that have been serviced
          counter(
            metric_prefix ++ [:http, :invalid, :requests, :total],
            event_name: cowboy_stop_event,
            description: "The number of invalid requests that have been serviced.",
            drop: drop_bad_route?(drop_bad_routes_fun),
            tag_values: &get_bad_tags(&1),
            tags: http_metrics_tags
          )
        ]
      )
    end
    
    defp get_tags(_ctx, :get), do:
      Process.get(:current_tags)

    defp get_tags(_ctx, :get_delete), do:
      Process.delete(:current_tags)

    defp get_tags(ctx, path_formatter_fun) do
       tags = do_get_tags(ctx, path_formatter_fun)
       Process.put(:current_tags, tags)
       tags
    end

    defp do_get_tags(%{resp_status: resp_status, req: %{method: method}} = ctx, path_formatter_fun) do
      case get_http_status(resp_status) do
        status when is_binary(status) ->
          %{
            status: status,
            method: method,
            path: path_formatter_fun.(ctx)
          }

        :undefined ->
          %{
            status: :undefined,
            method: method,
            path: path_formatter_fun.(ctx)
          }

        nil ->
          Logger.warning("Cowboy failed to provide valid response status #{inspect(resp_status)}")
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

    defp drop_good_route?(drop_good_routes_fun) do
      fn %{req: %{}} = ctx -> 
          result = drop_good_routes_fun.(ctx)
          Process.put(:current_drop_good_route, result)
          result;

        _meta ->
          true
      end
    end

    defp drop_bad_route?(drop_bad_routes_fun) do
      fn %{req: %{}} = ctx ->
          drop_bad_routes_fun.(ctx);

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
