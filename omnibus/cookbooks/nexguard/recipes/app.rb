# frozen_string_literal: true

# Cookbook:: nexguard
# Recipe:: app
#
# Copyright:: 2014 Chef Software, Inc.
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

include_recipe 'nexguard::config'
include_recipe 'nexguard::phoenix'

execute 'fix app permissions' do
  app_dir = node['nexguard']['app_directory']
  user = node['nexguard']['user']
  group = node['nexguard']['group']
  command "chown -R #{user}:#{group} #{app_dir} && chmod -R o-rwx #{app_dir} && chmod -R g-rwx #{app_dir}"
end

beam_path = `ls -1 #{node['nexguard']['install_directory']}/embedded/service/nexguard/erts-*/bin/beam.smp \
             | sort -nr | head -n 1 | tr -d '\n'`
execute 'setcap_beam' do
  command "setcap 'cap_net_admin+eip' #{beam_path}"
  node['nexguard']['phoenix']['enabled'] && notifies(:restart, 'component_runit_service[phoenix]', :delayed)
end

file 'environment-variables' do
  path "#{node['nexguard']['var_directory']}/etc/env"

  attributes = node['nexguard'].to_hash

  # Remove sensitive fields that aren't required for application startup
  attributes.delete('wireguard_private_key')
  attributes.delete('default_admin_password')

  # Add needed fields to top-level so they get added to application env and get
  # updated when config is updated.
  attributes.merge!(
    'mix_env' => 'prod'
  )

  content NexGuard::Config.environment_variables_from(attributes)
  owner node['nexguard']['user']
  group node['nexguard']['group']
  mode '0600'
end

execute 'database schema' do
  command 'bin/nexguard eval "FzHttp.Release.migrate"'
  cwd node['nexguard']['app_directory']
  environment(NexGuard::Config.app_env(node))
  user node['nexguard']['user']
end
