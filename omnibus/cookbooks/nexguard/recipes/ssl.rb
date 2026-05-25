# frozen_string_literal: true

#
# Cookbook:: nexguard
# Recipe:: ssl
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

[node['nexguard']['ssl']['directory'],
 "#{node['nexguard']['ssl']['directory']}/ca"].each do |dir|
  directory dir do
    owner node['nexguard']['user']
    group node['nexguard']['group']
    mode '0700'
  end
end

# Sets up SSL certificates.
# Creates a self-signed cert if none is provided.
nexguard_ca_dir = File.join(node['nexguard']['ssl']['directory'], 'ca')
ssl_dhparam = File.join(nexguard_ca_dir, 'dhparams.pem')

# Generate dhparams.pem for perfect forward secrecy
openssl_dhparam ssl_dhparam do
  key_length 2048
  generator 2
  owner 'root'
  group 'root'
  mode '0644'
end

node.default['nexguard']['ssl']['ssl_dhparam'] ||= ssl_dhparam

if node['nexguard']['ssl']['certificate']
  # A certificate has been supplied
  # Link the standard CA cert into our certs directory
  link "#{node['nexguard']['ssl']['directory']}/cacert.pem" do
    to "#{node['nexguard']['install_directory']}/embedded/ssl/certs/cacert.pem"
  end
elsif node['nexguard']['ssl']['acme']['enabled']
  # No certificate provided but acme enabled don't
  # auto-generate and ensure acme directory is setup
  directory "#{node['nexguard']['var_directory']}/ssl/acme" do
    owner 'root'
    group 'root'
    mode '0600'
  end

# No certificate has been supplied; generate one
else
  host = URI.parse(node['nexguard']['external_url']).host
  ssl_keyfile = File.join(nexguard_ca_dir, "#{host}.key")
  ssl_crtfile = File.join(nexguard_ca_dir, "#{host}.crt")

  openssl_x509_certificate ssl_crtfile do
    common_name host
    org node['nexguard']['ssl']['company_name']
    org_unit node['nexguard']['ssl']['organizational_unit_name']
    country node['nexguard']['ssl']['country_name']
    key_length 2048
    expire 3650
    owner 'root'
    group 'root'
    mode '0644'
  end

  node.default['nexguard']['ssl']['certificate'] ||= ssl_crtfile
  node.default['nexguard']['ssl']['certificate_key'] ||= ssl_keyfile

  link "#{node['nexguard']['ssl']['directory']}/cacert.pem" do
    to ssl_crtfile
  end
end

# SAML certs
host = URI.parse(node['nexguard']['external_url']).host
ssl_crtfile = File.join(node['nexguard']['ssl']['directory'], 'saml.crt')
openssl_x509_certificate ssl_crtfile do
  common_name host
  org node['nexguard']['ssl']['company_name']
  org_unit node['nexguard']['ssl']['organizational_unit_name']
  country node['nexguard']['ssl']['country_name']
  key_length 2048
  expire 3650
  owner 'root'
  group 'root'
  mode '0644'
end
