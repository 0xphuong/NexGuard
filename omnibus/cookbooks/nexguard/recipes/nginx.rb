# frozen_string_literal: true

#
# Cookbook:: nexguard
# Recipe:: nginx
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

[node['nexguard']['nginx']['cache']['directory'],
 node['nexguard']['nginx']['log_directory'],
 node['nexguard']['nginx']['directory'],
 "#{node['nexguard']['nginx']['directory']}/conf.d",
 "#{node['nexguard']['nginx']['directory']}/sites-enabled",
 "#{node['nexguard']['var_directory']}/nginx/acme_root",
 "#{node['nexguard']['var_directory']}/nginx/acme_root/.well-known",
 "#{node['nexguard']['var_directory']}/nginx/acme_root/.well-known/acme-challenge"].each do |dir|
  directory dir do
    owner node['nexguard']['user']
    group node['nexguard']['group']
    mode '0700'
    recursive true
  end
end

# Link the mime.types
link "#{node['nexguard']['nginx']['directory']}/mime.types" do
  to "#{node['nexguard']['install_directory']}/embedded/conf/mime.types"
end

template 'nginx.conf' do
  path "#{node['nexguard']['nginx']['directory']}/nginx.conf"
  source 'nginx.conf.erb'
  owner node['nexguard']['user']
  group node['nexguard']['group']
  mode '0600'
  variables(
    logging_enabled: node['nexguard']['logging']['enabled'],
    nginx: node['nexguard']['nginx']
  )
end

template 'redirect.conf' do
  path "#{node['nexguard']['nginx']['directory']}/redirect.conf"
  source 'redirect.conf.erb'
  owner 'root'
  group node['nexguard']['group']
  mode '0640'
  variables(
    server_name: URI.parse(node['nexguard']['external_url']).host,
    acme_www_root: "#{node['nexguard']['var_directory']}/nginx/acme_root",
    rate_limiting_zone_name: node['nexguard']['nginx']['rate_limiting_zone_name'],
    ipv6: node['nexguard']['nginx']['ipv6'],
    acme: node['nexguard']['ssl']['acme']
  )
end

if node['nexguard']['nginx']['enabled']
  component_runit_service 'nginx' do
    package 'nexguard'
    action :enable
    subscribes :restart, 'template[nginx.conf]'
    subscribes :restart, 'template[phoenix.nginx.conf]'
    subscribes :restart, 'template[redirect.conf]'
    subscribes :restart, 'template[acme.conf]'
  end
else
  runit_service 'nginx' do
    action :disable
  end
end

# setup log rotation with logrotate because nginx and runit's svlogd
# differ in opinion about who does the logging
template "#{node['nexguard']['var_directory']}/etc/logrotate.d/nginx" do
  source 'logrotate-rule.erb'
  owner 'root'
  group 'root'
  mode '0644'
  variables(
    'log_directory' => node['nexguard']['nginx']['log_directory'],
    'log_rotation' => node['nexguard']['nginx']['log_rotation'],
    'postrotate' => "#{node['nexguard']['install_directory']}/embedded/sbin/nginx -c "\
      "#{node['nexguard']['nginx']['directory']}/nginx.conf -s reopen",
    'owner' => 'root',
    'group' => 'root'
  )
end
