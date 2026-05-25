# frozen_string_literal: true

# Cookbook:: nexguard
# Recipe:: default
#
# Copyright:: 2021, NexGuard, All Rights Reserved.

include_recipe 'nexguard::config'
include_recipe 'nexguard::log_management'
include_recipe 'nexguard::ssl'
include_recipe 'nexguard::network'
include_recipe 'nexguard::postgresql'
include_recipe 'nexguard::nginx'
include_recipe 'nexguard::acme'
include_recipe 'nexguard::database'
include_recipe 'nexguard::setcap'
include_recipe 'nexguard::app'
include_recipe 'nexguard::telemetry'

running_config = "#{node['nexguard']['config_directory']}/nexguard-running.json"
if File.exist?(running_config)
  old_interface = Chef::JSONCompat.from_json(File.open(running_config).read)['nexguard']['wireguard']['interface_name']
end

# Write out a nexguard-running.json at the end of the run
file running_config do
  content Chef::JSONCompat.to_json_pretty('nexguard' => node['nexguard'])
  owner node['nexguard']['user']
  group node['nexguard']['group']
  mode '0600'
end

file "#{node['nexguard']['var_directory']}/.license.accepted" do
  content ''
  owner node['nexguard']['user']
  group node['nexguard']['group']
  mode '0600'
end

if File.exist?(running_config)
  # Run at the end to try to minimize VPN disruption.
  execute 'handle_interface_change' do
    only_if (old_interface != node['nexguard']['wireguard']['interface_name']).to_s
    command "ip link del dev #{old_interface}"
  end
end
