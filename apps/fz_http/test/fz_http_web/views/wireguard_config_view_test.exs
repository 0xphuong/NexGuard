defmodule FzHttpWeb.WireguardConfigViewTest do
  use FzHttp.DataCase, async: false

  alias FzHttp.DevicesFixtures
  alias FzHttpWeb.WireguardConfigView

  describe "device.conf rendering" do
    test "AllowedIPs auto-includes the L7 VIP CIDR even when defaults don't list it" do
      device = DevicesFixtures.create_device()

      conf = WireguardConfigView.render("device.conf", %{device: device})

      assert conf =~ ~r/AllowedIPs = .*10\.99\.0\.0\/16/,
             "expected L7 VIP /16 to be appended to AllowedIPs; got:\n#{conf}"
    end

    test "VIP CIDR is not duplicated if an admin already added it to defaults" do
      device = DevicesFixtures.create_device()

      # Override the default to include the VIP CIDR explicitly.
      FzHttp.Config.put_config!(:default_client_allowed_ips, ["10.99.0.0/16", "10.0.0.0/16"])

      conf = WireguardConfigView.render("device.conf", %{device: device})

      occurrences =
        conf
        |> String.split("10.99.0.0/16")
        |> length()
        |> Kernel.-(1)

      assert occurrences == 1,
             "VIP CIDR should appear exactly once in AllowedIPs; got #{occurrences} in:\n#{conf}"
    end
  end
end
