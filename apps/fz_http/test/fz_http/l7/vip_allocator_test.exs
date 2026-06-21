defmodule FzHttp.L7.VipAllocatorTest do
  use FzHttp.DataCase, async: false
  # async: false — exercises real Postgres advisory locks; running
  # concurrently with other suites that allocate VIPs would race.

  alias FzHttp.L7.VipAllocator
  alias FzHttp.ApplicationsFixtures

  describe "allocate/0" do
    test "returns the first free VIP starting from 10.99.0.1" do
      assert {:ok, %Postgrex.INET{address: {10, 99, 0, 1}, netmask: 32}} =
               VipAllocator.allocate()
    end

    test "successive allocations pick the next free offset" do
      assert {:ok, %Postgrex.INET{address: a}} = VipAllocator.allocate()
      # Insert an app at that VIP to make the offset "used".
      _app = ApplicationsFixtures.create_application(%{"hostname" => "vip-claim-1.test"})

      assert {:ok, %Postgrex.INET{address: b}} = VipAllocator.allocate()
      refute a == b
    end

    test "skips offsets already in applications.virtual_ip" do
      app = ApplicationsFixtures.create_application(%{"hostname" => "vip-skip.test"})

      # Allocate 5 more and confirm none collide with the seeded app.
      vips =
        for _ <- 1..5 do
          {:ok, vip} = VipAllocator.allocate()
          _ = ApplicationsFixtures.create_application(%{
                "hostname" => "vip-burn-#{System.unique_integer([:positive])}.test"
              })
          vip.address
        end

      refute app.virtual_ip.address in vips
      assert length(Enum.uniq(vips)) == 5
    end
  end

  describe "allocate_inside_transaction/0" do
    test "shares the caller's lock so VIP pick + INSERT are atomic" do
      {:ok, _} =
        FzHttp.Repo.transaction(fn ->
          vip = VipAllocator.allocate_inside_transaction()
          # We're inside a transaction holding the lock — another
          # process trying to allocate would block until commit.
          assert match?(%Postgrex.INET{address: {10, 99, _, _}, netmask: 32}, vip)
        end)
    end
  end

  describe "concurrency" do
    test "two concurrent allocate/0 calls produce different VIPs" do
      # Use Task.async to fire two concurrent transactions. The
      # advisory lock guarantees they serialise; we expect no
      # duplicate even though they race the SELECT max.
      tasks =
        for _ <- 1..2 do
          Task.async(fn ->
            {:ok, vip} = VipAllocator.allocate()
            # Hold the slot by inserting an app inside this test
            # process's connection ownership.
            ApplicationsFixtures.create_application(%{
              "hostname" => "concurrent-#{System.unique_integer([:positive])}.test"
            })

            vip.address
          end)
        end

      results = Enum.map(tasks, &Task.await/1)
      assert length(Enum.uniq(results)) == 2
    end
  end
end
