defmodule PromEx.Plugins.Application do
  @moduledoc """
  This plugin captures metrics regarding your application, and its dependencies. Specifically,
  it captures the versions of your application and the application dependencies and also
  how many modules each dependency is bringing into the project.

  This plugin supports the following options:
  - `otp_app`: This is a REQUIRED option and is the name of you application in snake case (e.g. :my_cool_app).

  - `deps`: This option is OPTIONAL and defines what dependencies the plugin should track. A value of `:all`
    means that PromEx will fetch details on all application dependencies. A list of dependency names like
    `[:phoenix, :ecto, :unplug]` means that PromEx will only fetch details regarding those dependencies.

  - `git_sha_mfa`: This option is OPTIONAL and defines an MFA that will be called in order to fetch the
    application's Git SHA at the time of deployment. By default, an Application Plugin function will be called
    and will attempt to read the GIT_SHA environment variable to populate the value.

  - `git_author_mfa`: This option is OPTIONAL and defines an MFA that will be called in order to fetch the
    application's last Git commit author at the time of deployment. By default, an Application Plugin function
    will be called and will attempt to read the GIT_AUTHOR environment variable to populate the value.

  - `metric_prefix`: This option is OPTIONAL and is used to override the default metric prefix of
    `[otp_app, :prom_ex, :application]`. If this changes you will also want to set `application_metric_prefix`
    in your `dashboard_assigns` to the snakecase version of your prefix, the default
    `application_metric_prefix` is `{otp_app}_prom_ex_application`.

  This plugin exposes the following metric groups:
  - `:application_versions_manual_metrics`

  To use plugin in your application, add the following to your application supervision tree:
  ```
  def start(_type, _args) do
    children = [
      ...
      {
        PromEx,
        plugins: [
          {PromEx.Plugins.Application, [otp_app: :my_cool_app]},
          ...
        ],
        delay_manual_start: :no_delay
      }
    ]

    opts = [strategy: :one_for_one, name: WebApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
  ```

  This plugin exposes manual metrics so be sure to configure the PromEx `:delay_manual_start` as required.
  """

  use PromEx.Plugin

  @proc_info_keys [:reductions, :message_queue_len, :total_heap_size, :registered_name]

  @filter_out_apps [
    :iex,
    :inets,
    :logger,
    :runtime_tools,
    :ssl,
    :crypto
  ]

  @impl true
  def manual_metrics(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    deps = Keyword.get(opts, :deps, :all)
    git_author_mfa = Keyword.get(opts, :git_author_mfa, {__MODULE__, :git_author, []})
    metric_prefix = Keyword.get(opts, :metric_prefix, PromEx.metric_prefix(otp_app, :application))

    [
      Manual.build(
        :application_versions_manual_metrics,
        {__MODULE__, :apps_running, [otp_app, deps, git_author_mfa]},
        [
          # Capture information regarding the primary application (i.e the user's application)
          last_value(
            metric_prefix ++ [:primary, :info],
            event_name: [otp_app | [:application, :primary, :info]],
            description: "Information regarding the primary application.",
            measurement: :status,
            tags: [:name, :version, :modules]
          ),

          # Capture information regarding the application dependencies (i.e the user's libs)
          last_value(
            metric_prefix ++ [:dependency, :info],
            event_name: [otp_app | [:application, :dependency, :info]],
            description: "Information regarding the application's dependencies.",
            measurement: :status,
            tags: [:name, :version, :modules]
          )
        ]
      )
    ]
  end

  @impl true
  def polling_metrics(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    poll_rate = Keyword.get(opts, :poll_rate, 5_000)
    metric_prefix = Keyword.get(opts, :metric_prefix, PromEx.metric_prefix(otp_app, :application))

    [Polling.build(
      :application_time_polling_metrics,
      poll_rate,
      {__MODULE__, :execute_time_metrics, []},
      [
        last_value(
          metric_prefix ++ [:uptime, :milliseconds, :count],
          event_name: [:prom_ex, :plugin, :application, :uptime, :count],
          description: "The total number of wall clock milliseconds that have passed since the application started.",
          measurement: :count,
          unit: :millisecond
        )
      ]
    ), 
    Polling.build(
      :application_reductions_polling_metrics,
      10000,
      {__MODULE__, :get_top_process, [:reductions, true]},
      [
        last_value(
          metric_prefix ++ [:reductions, :status],
          event_name: [:prom_ex, :plugin, :application, :reductions, :status],
          description: "Registered Collection Server process with the most reductions since last invocation.",
          measurement: :status,
          tags: [:data]
        )
      ]
    ),
    Polling.build(
      :application_total_heap_size_polling_metrics,
      10000,
      {__MODULE__, :get_top_process, [:total_heap_size, false]},
      [
        last_value(
          metric_prefix ++ [:total_heap_size, :status],
          event_name: [:prom_ex, :plugin, :application, :total_heap_size, :status],
          description: "Registered Collection Server process consuming the most memory.",
          measurement: :status,
          tags: [:data]
        )
      ]),
    Polling.build(
      :application_message_queue_len_polling_metrics,
      10000,
      {__MODULE__, :get_top_process, [:message_queue_len, false]},
      [
        last_value(
          metric_prefix ++ [:message_queue_len, :status],
          event_name: [:prom_ex, :plugin, :application, :message_queue_len, :status],
          description: "Registered Collection Server process witht the longest message queue.",
          measurement: :status,
          tags: [:data]
        )
      ])]
  end

  @doc false
  def execute_time_metrics do
    {wall_clock_time, _} = :erlang.statistics(:wall_clock)
    :telemetry.execute([:prom_ex, :plugin, :application, :uptime, :count], %{count: wall_clock_time})
  end

  @doc false
  def git_sha do
    case System.fetch_env("GIT_SHA") do
      {:ok, git_sha} ->
        git_sha

      :error ->
        "Git SHA not available"
    end
  end

  @doc false
  def git_author do
    case System.fetch_env("GIT_AUTHOR") do
      {:ok, git_sha} ->
        git_sha

      :error ->
        "Git author not available"
    end
  end

  @doc false
  def apps_running(otp_app, deps, git_author_mfa) do
    # Loop through all of the dependencies
    filtered_deps =
      if deps == :all do
        otp_app
        |> Application.spec()
        |> Keyword.get(:applications)
        |> Enum.reject(fn
          app when app in @filter_out_apps -> true
          _ -> false
        end)
      else
        deps
      end

    filtered_deps
    |> Enum.each(fn app ->
      :telemetry.execute(
        [otp_app | [:application, :dependency, :info]],
        %{status: 1},
        %{
          name: app,
          version: Application.spec(app)[:vsn],
          modules: length(Application.spec(app)[:modules])
        }
      )
    end)

    # Emit primary app details
    :telemetry.execute(
      [otp_app | [:application, :primary, :info]],
      %{status: 1},
      %{
        name: otp_app,
        version: Application.spec(otp_app)[:vsn],
        modules: length(Application.spec(otp_app)[:modules])
      }
    )

    # Publish Git author data
    {module, function, args} = git_author_mfa
    git_author = apply(module, function, args)

    :telemetry.execute(
      [otp_app | [:application, :git_author, :info]],
      %{status: 1},
      %{author: git_author}
    )
  end

  @doc false 
  def get_top_process(key, delta) do
     value = get_cs_registered() 
     |> Enum.map(&(Keyword.take(Process.info(Process.whereis(&1)), @proc_info_keys)++[pid: &1])) 
     |> get_cs_deltas(key, delta)
     |> Enum.sort_by(&(&1[key]), :desc)  
     |> hd() 

    name = value[:registered_name] |> Atom.to_string() |> String.split(".") |> List.last()
    data = "#{name} : #{inspect(value[key])}"

    :ets.select_delete(Elixir.CollectionServer.PromEx.Metrics, [{{{[:collection_server, :prom_ex, :application, key, :status], :_}, :_}, [], [true]}])
    :telemetry.execute([:prom_ex, :plugin, :application, key, :status], %{status: value[key]}, %{data: data})
  end
 
  defp get_cs_registered() do
     Process.registered() 
     |> Enum.filter(fn mod -> 
           Atom.to_string(mod) 
           |> String.split(".") 
           |> name_filter()
     end)
  end

  defp name_filter(data) do
     Enum.member?(data, "CollectionServer") and not Enum.member?(data, "PromEx")
  end
 
  defp get_cs_deltas(new_data, key, true) do
    res = Enum.map(new_data, fn new_info -> 
       case :ets.lookup(:prom_ex_proc_delta, new_info[:registered_name]) do
         [{_, old_info}] -> [{:registered_name, new_info[:registered_name]}, {key, new_info[key] - old_info[key]}]
         _ -> [{:registered_name, new_info[:registered_name]}, {key, new_info[key]}]
       end
    end)	
    :ets.delete_all_objects(:prom_ex_proc_delta)
    Enum.map(new_data, &(:ets.insert(:prom_ex_proc_delta, {&1[:registered_name],&1})))
    res
  end

  defp get_cs_deltas(new_data, _, _), do:
    new_data
end
