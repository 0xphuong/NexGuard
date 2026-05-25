# frozen_string_literal: true

# Cookbook:: nexguard
# Recipe:: telemetry
#
# Copyright:: 2022, NexGuard, All Rights Reserved.

# Configure telemetry app-wide.

include_recipe 'nexguard::config'

disable_telemetry_path = "#{node['nexguard']['var_directory']}/.disable_telemetry"

if node['nexguard']['telemetry']['enabled'] == false
  file 'disable_telemetry' do
    path disable_telemetry_path
    mode '0644'
    user node['nexguard']['user']
    group node['nexguard']['group']
  end
else
  file 'disable_telemetry' do
    path disable_telemetry_path
    action :delete
  end
end
