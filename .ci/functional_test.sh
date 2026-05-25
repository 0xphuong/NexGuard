#!/bin/bash
set -ex
# This script should be run from the app root

function print_logs() {
  sudo cat /var/log/nexguard/nginx/current
  sudo cat /var/log/nexguard/postgresql/current
  sudo cat /var/log/nexguard/phoenix/current
  sudo cat /var/log/nexguard/wireguard/current
}

trap print_logs EXIT

# Disable telemetry
sudo mkdir -p /opt/nexguard/
sudo touch /opt/nexguard/.disable-telemetry

if type rpm > /dev/null; then
  sudo -E rpm -i omnibus/pkg/nexguard*.rpm
elif type dpkg > /dev/null; then
  sudo -E dpkg -i omnibus/pkg/nexguard*.deb
else
  echo 'Neither rpm nor dpkg found'
  exit 1
fi

# Fixes setcap not found on centos 7
PATH=/usr/sbin/:$PATH

# Disable connectivity checks
conf="/opt/nexguard/embedded/cookbooks/nexguard/attributes/default.rb"
search="default\['nexguard']\['connectivity_checks']\['enabled'] = true"
replace="default['nexguard']['connectivity_checks']['enabled'] = false"
sudo -E sed -i "s/$search/$replace/" $conf

# Disable telemetry
search="default\['nexguard']\['telemetry']\['enabled'] = true"
search="default['nexguard']['telemetry']['enabled'] = false"
sudo -E sed -i "s/$search/$replace/" $conf

# Bootstrap config
sudo -E nexguard-ctl reconfigure

# Wait for app to fully boot
sleep 5

# Helpful for debugging
print_logs

# Create admin; requires application to be up
sudo -E nexguard-ctl create-or-reset-admin

# XXX: Add more commands here to test

echo "Trying to load homepage"
page=$(curl -L -i -vvv -k https://localhost)
echo $page

echo "Testing for sign in button"
echo $page | grep '<a class="button" href="/auth/identity">Sign in with email</a>'

echo "Testing telemetry_id survives reconfigures"
tid1=`sudo cat /var/opt/nexguard/cache/telemetry_id`
sudo nexguard-ctl reconfigure
tid2=`sudo cat /var/opt/nexguard/cache/telemetry_id`

if [ "$tid1" = "$tid2" ]; then
  echo "telemetry_ids match!"
else
  echo "telemetry_ids differ:"
  echo $tid1
  echo $tid2
  exit 1
fi

fz_bin="/opt/nexguard/embedded/service/nexguard/bin/nexguard"
ok_res=":ok"

echo "Testing FzVpn.Interface module works with WireGuard"
set_interface=`sudo $fz_bin rpc "IO.inspect(FzVpn.Interface.set(\"wg-fz-test\", %{}))"`
del_interface=`sudo $fz_bin rpc "IO.inspect(FzVpn.Interface.delete(\"wg-fz-test\"))"`

if [[ "$set_interface" != $ok_res || "$del_interface" != $ok_res ]]; then
    echo "WireGuard test failed!"
    exit 1
fi

echo "Testing Firewall Rules"
user_id="5" # Picking a high enough user_id so there is no overlap
device="%{ip: \"10.0.0.1\", ip6: \"fd00::3:2:1\", user_id: $user_id}"
rule="%{destination: \"10.0.0.2\", user_id: $user_id, action: :drop, port_type: nil, port_range: nil}"
add_user=`sudo $fz_bin rpc "IO.inspect(FzWall.CLI.Live.add_user($user_id))"`
add_device=`sudo $fz_bin rpc "IO.inspect(FzWall.CLI.Live.add_device($device))"`
add_rule=`sudo $fz_bin rpc "IO.inspect(FzWall.CLI.Live.add_rule($rule))"`
del_rule=`sudo $fz_bin rpc "IO.inspect(FzWall.CLI.Live.delete_rule($rule))"`
del_device=`sudo $fz_bin rpc "IO.inspect(FzWall.CLI.Live.delete_device($device))"`
del_user=`sudo $fz_bin rpc "IO.inspect(FzWall.CLI.Live.delete_user($user_id))"`

if [[ "$add_user" != $ok_res || "$add_device" != $ok_res || "$add_rule" != '""' || "$del_rule" != '""' || "$del_device" != $ok_res || "$del_user" != $ok_res ]]; then
    echo "Firewall test failed!"
    exit 1
fi
