# frozen_string_literal: true

# Cookbook:: nexguard
# Recipe:: wireguard
#
# Copyright:: 2021, NexGuard, All Rights Reserved.

# Sets up service to manage WireGuard interface

include_recipe 'nexguard::config'

directory node['nexguard']['wireguard']['log_directory'] do
  owner node['nexguard']['user']
  group node['nexguard']['group']
  mode '0700'
  recursive true
end

if node['nexguard']['wireguard']['enabled']
  component_runit_service 'wireguard' do
    package 'nexguard'
    action :enable
    subscribes :restart, 'template[sv-wireguard-run]'
  end
else
  runit_service 'wireguard' do
    action :disable
  end
end
