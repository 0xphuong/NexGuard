# frozen_string_literal: true

# Cookbook:: nexguard
# Recipe:: phoenix
#
# Copyright:: 2014 Chef Software, Inc.
# Copyright:: 2021 NexGuard
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

# Common configuration for Phoenix

include_recipe 'nexguard::config'
include_recipe 'nexguard::nginx'
include_recipe 'nexguard::acme'
include_recipe 'nexguard::ssl'
include_recipe 'nexguard::wireguard'

fqdn = URI.parse(node['nexguard']['external_url']).host
acme_cert = "#{node['nexguard']['var_directory']}/ssl/acme/#{fqdn}.fullchain"
acme_key = "#{node['nexguard']['var_directory']}/ssl/acme/#{fqdn}.key"

[node['nexguard']['phoenix']['log_directory'],
 "#{node['nexguard']['var_directory']}/phoenix/run"].each do |dir|
  directory dir do
    owner node['nexguard']['user']
    group node['nexguard']['group']
    mode '0700'
    recursive true
  end
end

if node['nexguard']['ssl']['acme']['enabled']
  # Generate a temporary cert until ACME issues one so that nginx can be restarted
  openssl_x509_certificate acme_cert do
    common_name fqdn
    org node['nexguard']['ssl']['company_name']
    org_unit node['nexguard']['ssl']['organizational_unit_name']
    country node['nexguard']['ssl']['country_name']
    key_length 2048
    expire 3650
    owner 'root'
    group 'root'
    mode '0644'
  end
end

template 'phoenix.nginx.conf' do
  path "#{node['nexguard']['nginx']['directory']}/sites-enabled/phoenix"
  source 'phoenix.nginx.conf.erb'
  owner node['nexguard']['user']
  group node['nexguard']['group']
  mode '0600'
  variables(nginx: node['nexguard']['nginx'],
            logging_enabled: node['nexguard']['logging']['enabled'],
            phoenix: node['nexguard']['phoenix'],
            fqdn: fqdn,
            fips_enabled: node['nexguard']['fips_enabled'],
            ssl: node['nexguard']['ssl'],
            app_directory: node['nexguard']['app_directory'],
            acme: {
              'enabled' => node['nexguard']['ssl']['acme']['enabled'],
              'certificate' => acme_cert,
              'certificate_key' => acme_key
            })
end

if node['nexguard']['phoenix']['enabled']
  component_runit_service 'phoenix' do
    runit_attributes(
      env: NexGuard::Config.app_env(node),
      finish: true
    )
    package 'nexguard'
    control ['t']
    action :enable
    subscribes :restart, 'file[environment-variables]'
    subscribes :restart, 'file[disable-telemetry]'
  end
else
  runit_service 'phoenix' do
    action :disable
  end
end
