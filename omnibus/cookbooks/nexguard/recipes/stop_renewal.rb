# frozen_string_literal: true

# Cookbook:: nexguard
# Recipe:: stop_renewal
#
# Copyright:: 2021, NexGuard, All Rights Reserved.

# Removes cronjob renewing certificates. Used during uninstall.

include_recipe 'nexguard::config'

require 'mixlib/shellout'

bin_path = "#{node['nexguard']['install_directory']}/embedded/bin"

# Remove cronjob (if cronjob doesn't exist no harm is done)
execute 'ACME remove cronjob' do
  command <<~ACME
    #{bin_path}/acme.sh --uninstall-cronjob
  ACME
end
