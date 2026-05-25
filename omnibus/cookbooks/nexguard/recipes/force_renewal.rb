# frozen_string_literal: true

# Cookbook:: nexguard
# Recipe:: force_renewal
#
# Copyright:: 2021, NexGuard, All Rights Reserved.

# Force certificate to renew now even if it hasn't expired.

include_recipe 'nexguard::config'

require 'mixlib/shellout'

server = node['nexguard']['ssl']['acme']['server']
keylength = node['nexguard']['ssl']['acme']['keylength']
bin_path = "#{node['nexguard']['install_directory']}/embedded/bin"
acme_home = "#{node['nexguard']['var_directory']}/#{server}/#{keylength}/acme"

execute 'ACME force cronjob' do
  command <<~ACME
    #{bin_path}/acme.sh --cron \
    --force \
    --home #{acme_home}
  ACME
end
