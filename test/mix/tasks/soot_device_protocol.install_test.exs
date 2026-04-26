defmodule Mix.Tasks.SootDeviceProtocol.InstallTest do
  use ExUnit.Case, async: false

  import Igniter.Test

  describe "info/2" do
    test "exposes the documented option schema" do
      info = Mix.Tasks.SootDeviceProtocol.Install.info([], nil)
      assert info.group == :soot
      assert info.schema == [example: :boolean, yes: :boolean]
      assert info.aliases == [y: :yes, e: :example]
      assert info.composes == []
    end
  end

  describe "formatter" do
    test "imports :soot_device_protocol in .formatter.exs" do
      test_project(files: %{})
      |> Igniter.compose_task("soot_device_protocol.install", [])
      |> assert_has_patch(".formatter.exs", """
      + |  import_deps: [:soot_device_protocol]
      """)
    end

    test "is idempotent on .formatter.exs" do
      test_project(files: %{})
      |> Igniter.compose_task("soot_device_protocol.install", [])
      |> apply_igniter!()
      |> Igniter.compose_task("soot_device_protocol.install", [])
      |> assert_unchanged(".formatter.exs")
    end
  end

  describe "config helper module" do
    test "creates lib/<app>/soot_device_config.ex" do
      test_project(files: %{})
      |> Igniter.compose_task("soot_device_protocol.install", [])
      |> assert_creates("lib/test/soot_device_config.ex")
    end

    test "the generated module exposes protocol_opts/1 with the documented shape" do
      result =
        test_project(files: %{})
        |> Igniter.compose_task("soot_device_protocol.install", [])

      diff = diff(result, only: "lib/test/soot_device_config.ex")
      assert diff =~ "def protocol_opts"
      assert diff =~ "fetch!(:enroll_url)"
      assert diff =~ "fetch!(:contract_url)"
      assert diff =~ "fetch!(:serial)"
      assert diff =~ "SootDeviceProtocol.Storage.Local"
      assert diff =~ "SootDeviceProtocol.Storage.Memory"
    end
  end

  describe "config seed" do
    test "seeds :contract_url, :enroll_url, :serial, cert paths, storage, persistence_dir" do
      result =
        test_project(files: %{})
        |> Igniter.compose_task("soot_device_protocol.install", [])

      diff = diff(result, only: "config/config.exs")
      assert diff =~ "contract_url:"
      assert diff =~ "enroll_url:"
      assert diff =~ "serial:"
      assert diff =~ "bootstrap_cert_path:"
      assert diff =~ "bootstrap_key_path:"
      assert diff =~ "operational_storage:"
      assert diff =~ "persistence_dir:"
      assert diff =~ "TEST_CONTRACT_URL"
      assert diff =~ "TEST_ENROLL_URL"
    end

    test "is idempotent on config.exs" do
      test_project(files: %{})
      |> Igniter.compose_task("soot_device_protocol.install", [])
      |> apply_igniter!()
      |> Igniter.compose_task("soot_device_protocol.install", [])
      |> assert_unchanged("config/config.exs")
    end
  end

  describe "supervision tree" do
    test "adds {SootDeviceProtocol.Supervisor, ...} to the application" do
      result =
        test_project(files: %{})
        |> Igniter.compose_task("soot_device_protocol.install", [])

      diff = diff(result)
      assert diff =~ "SootDeviceProtocol.Supervisor"
      assert diff =~ "Test.SootDeviceConfig.protocol_opts()"
    end

    test "is idempotent on the application module" do
      test_project(files: %{})
      |> Igniter.compose_task("soot_device_protocol.install", [])
      |> apply_igniter!()
      |> Igniter.compose_task("soot_device_protocol.install", [])
      |> assert_unchanged("lib/test/application.ex")
    end
  end

  describe "next-steps notice" do
    test "always emits a soot_device_protocol installed notice" do
      igniter =
        test_project(files: %{})
        |> Igniter.compose_task("soot_device_protocol.install", [])

      assert Enum.any?(igniter.notices, &(&1 =~ "soot_device_protocol installed"))
    end
  end
end
