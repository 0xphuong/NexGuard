defmodule FzHttp.L7.BundleBuilderTest do
  # async: false — both JwtSigner and BundleBuilder are registered under
  # their canonical names so the controller layer can reach them; parallel
  # tests would collide on those names. Shared sandbox mode is needed
  # anyway since the GenServers query Repo from spawned processes.
  use FzHttp.DataCase, async: false

  alias FzHttp.AccessGroupsFixtures
  alias FzHttp.L7.{BundleBuilder, JwtSigner}
  alias Phoenix.PubSub

  setup do
    # Unique table name per test so ETS state doesn't leak between runs.
    table = :"l7_bundle_test_#{System.unique_integer([:positive])}"

    start_supervised!({JwtSigner, name: JwtSigner})

    # subscribe: false so source-of-truth topics don't push test events
    # into other tests' BundleBuilders running in the same VM.
    # compile_on_boot: false so we control when version 1 is written.
    start_supervised!(
      {BundleBuilder, name: BundleBuilder, table: table, subscribe: false, compile_on_boot: false}
    )

    {:ok, 1} = BundleBuilder.compile_now()

    {:ok, table: table}
  end

  describe "compile" do
    test "writes a bundle with the documented schema", %{table: table} do
      entry = BundleBuilder.current(table)
      assert %{version: 1, bundle_json: json, signature: sig, compiled_at: _ts} = entry

      bundle = Jason.decode!(json)

      assert bundle["schema_version"] == 1
      assert bundle["bundle_version"] == 1
      assert bundle["org_settings"]["l7_enabled"] in [true, false]
      assert is_list(bundle["jwks"])
      assert is_list(bundle["apps"])
      assert is_list(bundle["groups"])
      assert is_binary(sig)
    end

    test "signature is a valid JwtSigner JWS over SHA-256 of the body", %{table: table} do
      %{bundle_json: json, signature: sig} = BundleBuilder.current(table)

      assert {:ok, claims} = JwtSigner.verify(sig)

      expected_sha =
        :crypto.hash(:sha256, json) |> Base.encode16(case: :lower)

      assert claims["bundle_sha256"] == expected_sha
    end

    test "compile_now bumps the version monotonically", %{table: _table} do
      {:ok, v2} = BundleBuilder.compile_now()
      {:ok, v3} = BundleBuilder.compile_now()

      assert v2 == 2
      assert v3 == 3
    end

    test "groups in the bundle carry user_ids", %{table: table} do
      user = FzHttp.UsersFixtures.create_user_with_role(:unprivileged)
      group = AccessGroupsFixtures.create_group()
      subject = FzHttp.SubjectFixtures.create_subject()
      {:ok, _m} = FzHttp.AccessGroups.add_member(group, user, subject)

      {:ok, _v} = BundleBuilder.compile_now()

      %{bundle_json: json} = BundleBuilder.current(table)
      bundle = Jason.decode!(json)

      assert Enum.any?(bundle["groups"], fn g ->
               g["id"] == group.id and user.id in g["user_ids"]
             end)
    end
  end

  describe "broadcast" do
    test "publishes {:bundle_updated, version} after each compile" do
      BundleBuilder.subscribe_updates()
      {:ok, version} = BundleBuilder.compile_now()

      assert_receive {:bundle_updated, ^version}, 1_000
    end
  end

  describe "history (LKG ring)" do
    test "keeps last @history_size versions", %{table: table} do
      # Already at version 1 from setup. Compile 4 more → versions 2..5.
      for _ <- 1..4, do: BundleBuilder.compile_now()

      assert BundleBuilder.current(table).version == 5
      # Ring size = 3 → versions 3, 4, 5 retained; 1, 2 evicted.
      assert BundleBuilder.history(table, 5)
      assert BundleBuilder.history(table, 4)
      assert BundleBuilder.history(table, 3)
      refute BundleBuilder.history(table, 2)
      refute BundleBuilder.history(table, 1)
    end
  end

  describe "debounce" do
    test "coalesces a burst of source events into a single compile", %{table: table} do
      v_before = BundleBuilder.current(table).version

      # Send 5 broadcasts back-to-back. Each schedules/cancels a timer;
      # only the last one's 300 ms fires.
      pid = Process.whereis(BundleBuilder)
      for _ <- 1..5, do: send(pid, :apps_changed)

      # Wait past the debounce window + slack.
      Process.sleep(500)

      v_after = BundleBuilder.current(table).version

      # Exactly ONE compile should have fired (version bumped by 1).
      assert v_after == v_before + 1
    end
  end
end
