defmodule Mix.Tasks.SootDeviceProtocol.Install.Docs do
  @moduledoc false

  def short_doc do
    "Installs the soot_device_protocol imperative device runtime into a project"
  end

  def example do
    "mix igniter.install soot_device_protocol"
  end

  def long_doc do
    """
    #{short_doc()}

    Wires the imperative device runtime (`SootDeviceProtocol.Supervisor`)
    into a project's supervision tree, generates a small
    `<App>.SootDeviceConfig` helper that builds the supervisor's option
    keyword list from `Application` env, and seeds `config/config.exs`
    with placeholder keys for the URLs, serial, bootstrap cert paths,
    operational storage strategy, and persistence directory.

    The result is a project that boots a Soot device runtime as soon as
    `:#{:contract_url}` and friends are filled in (typically via
    environment variables on the target).

    Use this installer when you want imperative control over enrollment,
    contract refresh, MQTT, shadow, commands, and telemetry. For a
    higher-level declarative DSL, use `mix igniter.install soot_device`
    instead — the two are alternatives, not layers.

    ## Example

    ```bash
    mix nerves.new my_device --target qemu_aarch64
    cd my_device
    # add {:soot_device_protocol, "~> 0.1"} (or path:) to deps
    mix deps.get
    #{example()}
    ```

    ## Options

      * `--example` — currently a no-op; reserved for future use to
        seed example device behavior.
      * `--yes` — answer "yes" to dependency-fetching prompts.
    """
  end
end

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.SootDeviceProtocol.Install do
    @shortdoc "#{__MODULE__.Docs.short_doc()}"
    @moduledoc __MODULE__.Docs.long_doc()

    use Igniter.Mix.Task

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :soot,
        example: __MODULE__.Docs.example(),
        only: nil,
        composes: [],
        schema: [example: :boolean, yes: :boolean],
        defaults: [example: false, yes: false],
        aliases: [y: :yes, e: :example]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      app_name = Igniter.Project.Application.app_name(igniter)
      config_module = Igniter.Project.Module.module_name(igniter, "SootDeviceConfig")

      igniter
      |> Igniter.Project.Formatter.import_dep(:soot_device_protocol)
      |> create_config_module(config_module, app_name)
      |> seed_application_config(app_name)
      |> add_supervisor_child(config_module)
      |> note_next_steps(app_name)
    end

    defp create_config_module(igniter, config_module, app_name) do
      Igniter.Project.Module.create_module(
        igniter,
        config_module,
        """
        @moduledoc \"\"\"
        Reads the device-side configuration that
        `SootDeviceProtocol.Supervisor` needs.

        Centralising this here keeps `Application.start/2` clean and
        gives test harnesses one place to override values.

        Generated stub — adjust freely as your config grows.
        \"\"\"

        @app :#{app_name}

        @doc \"\"\"
        Builds the keyword list handed to
        `SootDeviceProtocol.Supervisor.start_link/1`.
        \"\"\"
        @spec protocol_opts(keyword()) :: keyword()
        def protocol_opts(overrides \\\\ []) do
          [
            storage: storage_binding(),
            enrollment: [
              enroll_url: fetch!(:enroll_url),
              bootstrap_cert: read_optional_file(fetch!(:bootstrap_cert_path)),
              bootstrap_key: read_optional_file(fetch!(:bootstrap_key_path)),
              subject: "/CN=" <> fetch!(:serial)
            ],
            contract_refresh: [
              url: fetch!(:contract_url)
            ]
          ]
          |> Keyword.merge(overrides)
        end

        @doc "Fetches a single config key, raising if unset."
        @spec fetch!(atom()) :: term()
        def fetch!(key) do
          case Application.fetch_env(@app, key) do
            {:ok, value} -> value
            :error -> raise "missing " <> inspect(@app) <> " config key " <> inspect(key)
          end
        end

        defp storage_binding do
          dir = fetch!(:persistence_dir)

          case fetch!(:operational_storage) do
            :memory -> SootDeviceProtocol.Storage.Memory.open!()
            :file_system -> SootDeviceProtocol.Storage.Local.open!(dir)
          end
        end

        defp read_optional_file(nil), do: nil

        defp read_optional_file(path) when is_binary(path) do
          case File.read(path) do
            {:ok, contents} -> contents
            {:error, :enoent} -> nil
          end
        end
        """
      )
    end

    defp seed_application_config(igniter, app_name) do
      env_prefix = app_name |> Atom.to_string() |> String.upcase()

      igniter
      |> set_config(app_name, :contract_url, """
      System.get_env("#{env_prefix}_CONTRACT_URL", "http://localhost:4000/.well-known/soot/contract")\
      """)
      |> set_config(app_name, :enroll_url, """
      System.get_env("#{env_prefix}_ENROLL_URL", "http://localhost:4000/enroll")\
      """)
      |> set_config(app_name, :serial, """
      System.get_env("#{env_prefix}_SERIAL", "DEV-0000-000001")\
      """)
      |> set_config(app_name, :bootstrap_cert_path, """
      System.get_env("#{env_prefix}_BOOTSTRAP_CERT", "priv/pki/bootstrap.pem")\
      """)
      |> set_config(app_name, :bootstrap_key_path, """
      System.get_env("#{env_prefix}_BOOTSTRAP_KEY", "priv/pki/bootstrap.key")\
      """)
      |> set_config(app_name, :operational_storage, ":file_system")
      |> set_config(app_name, :persistence_dir, """
      System.get_env("#{env_prefix}_PERSISTENCE_DIR", "/data/soot")\
      """)
    end

    defp set_config(igniter, app_name, key, code_string) do
      Igniter.Project.Config.configure(
        igniter,
        "config.exs",
        app_name,
        [key],
        {:code, Sourceror.parse_string!(code_string)}
      )
    end

    defp add_supervisor_child(igniter, config_module) do
      child_opts_ast =
        quote do
          unquote(config_module).protocol_opts()
        end

      Igniter.Project.Application.add_new_child(
        igniter,
        {SootDeviceProtocol.Supervisor, {:code, child_opts_ast}}
      )
    end

    defp note_next_steps(igniter, app_name) do
      env_prefix = app_name |> Atom.to_string() |> String.upcase()

      Igniter.add_notice(igniter, """
      soot_device_protocol installed.

      Generated:
        * `lib/#{app_name}/soot_device_config.ex` — builds the supervisor opts.
        * `{SootDeviceProtocol.Supervisor, ...}` is now in your application
          supervision tree.
        * `config/config.exs` seeded with placeholder
          `:#{app_name}, :contract_url` etc., env-overridable via
          `#{env_prefix}_CONTRACT_URL`, `#{env_prefix}_ENROLL_URL`,
          `#{env_prefix}_SERIAL`, `#{env_prefix}_BOOTSTRAP_CERT`,
          `#{env_prefix}_BOOTSTRAP_KEY`, `#{env_prefix}_PERSISTENCE_DIR`.

      Next steps:

        1. Drop a bootstrap cert + key under `priv/pki/` (or point
           `#{env_prefix}_BOOTSTRAP_CERT` / `_KEY` at the right paths
           on your target). The backend operator hands these out as
           part of pre-provisioning.
        2. Set `#{env_prefix}_CONTRACT_URL` and friends to the URLs
           your Soot backend is serving from.
        3. Boot the app — the supervisor blocks on enrollment, then
           starts contract refresh and (if configured) MQTT.

      For the higher-level DSL with declarative `identity`, `shadow`,
      `commands`, and `telemetry` blocks, see `mix igniter.install soot_device`.
      """)
    end
  end
else
  defmodule Mix.Tasks.SootDeviceProtocol.Install do
    @shortdoc "#{__MODULE__.Docs.short_doc()} | Install `igniter` to use"
    @moduledoc __MODULE__.Docs.long_doc()

    use Mix.Task

    def run(_argv) do
      Mix.shell().error("""
      The task `soot_device_protocol.install` requires igniter. Add
      `{:igniter, "~> 0.6"}` to your project deps and try again, or
      invoke via:

          mix igniter.install soot_device_protocol

      For more information, see https://hexdocs.pm/igniter
      """)

      exit({:shutdown, 1})
    end
  end
end
