# frozen_string_literal: true

require 'securerandom'

# Cookbook:: nexguard
# Recipe:: config
#
# Copyright:: 2014 Chef Software, Inc.
# Copyright:: 2021 NexGuard, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# Get and/or create config and secrets.
#
# This creates the config_directory if it does not exist as well as the files
# in it.

NexGuard::Config.load_or_create!(
  "#{node['nexguard']['config_directory']}/nexguard.rb",
  node
)
NexGuard::Config.load_or_create_telemetry_id("#{node['nexguard']['var_directory']}/cache/telemetry_id", node)
NexGuard::Config.load_from_json!(
  "#{node['nexguard']['config_directory']}/nexguard.json",
  node
)
NexGuard::Config.load_or_create_secrets!(
  "#{node['nexguard']['config_directory']}/secrets.json",
  node
)

NexGuard::Config.audit_config(node['nexguard'])
NexGuard::Config.maybe_turn_on_fips(node)

# Set SSL email address to admin's email if none was provided.
node.default['nexguard']['ssl']['email_address'] ||= node['nexguard']['admin_email']

# Copy things we need from the nexguard namespace to the top level. This is
# necessary for some community cookbooks.
node.consume_attributes('runit' => node['nexguard']['runit'])

user node['nexguard']['user']

group node['nexguard']['group'] do
  members [node['nexguard']['user']]
end

directory node['nexguard']['config_directory'] do
  owner node['nexguard']['user']
  group node['nexguard']['group']
end

directory node['nexguard']['var_directory'] do
  owner node['nexguard']['user']
  group node['nexguard']['group']
  mode '0700'
  recursive true
end

directory "#{node['nexguard']['app_directory']}/tmp" do
  owner node['nexguard']['user']
  group node['nexguard']['group']
  mode '0700'
  recursive true
end

directory node['nexguard']['log_directory'] do
  owner node['nexguard']['user']
  group node['nexguard']['group']
  mode '0700'
  recursive true
end

directory "#{node['nexguard']['var_directory']}/etc" do
  owner node['nexguard']['user']
  group node['nexguard']['group']
  mode '0700'
end

file 'configuration-variables' do
  path "#{node['nexguard']['config_directory']}/nexguard.rb"
  owner node['nexguard']['user']
  group node['nexguard']['group']
  mode '0600'
end

file "#{node['nexguard']['config_directory']}/secrets.json" do
  owner node['nexguard']['user']
  group node['nexguard']['group']
  mode '0600'
end

file "#{node['nexguard']['var_directory']}/cache/wg_private_key" do
  owner node['nexguard']['user']
  group node['nexguard']['group']
  mode '0600'
end
