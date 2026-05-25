# frozen_string_literal: true

# Cookbook:: nexguard
# Recipe:: teardown
#
# Copyright:: 2021, NexGuard, All Rights Reserved.

# Teardown all the network settings. Used during uninstall.

include_recipe 'nexguard::config'

require 'mixlib/shellout'

wg_interface = node['nexguard']['wireguard']['interface_name']
nft_path = "#{node['nexguard']['install_directory']}/embedded/sbin/nft"

# Delete wireguard interface if exists
wg_exists = Mixlib::ShellOut.new("ip link show dev #{wg_interface}")
wg_exists.run_command
if wg_exists.status.exitstatus.zero?
  execute 'delete_wireguard_interface' do
    command "ip link delete dev #{wg_interface}"
  end
end

# Delete firewall table
table_exists_cmd = Mixlib::ShellOut.new("#{nft_path} list table inet nexguard")
table_exists_cmd.run_command
if table_exists_cmd.status.exitstatus.zero?
  execute 'delete_firewall_table' do
    command "#{nft_path} delete table inet nexguard"
  end
end
