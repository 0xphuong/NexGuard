# frozen_string_literal: true

# Cookbook:: nexguard
# Recipe:: database
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

include_recipe 'nexguard::config'

# The enterprise_pg resources use the CLI to create databases and users. Set
# these environment variables so the commands have the correct connection
# settings.

ENV['PGHOST'] = node['nexguard']['database']['host']
ENV['PGPORT'] = node['nexguard']['database']['port'].to_s
ENV['PGUSER'] = node['nexguard']['database']['user']
ENV['PGPASSWORD'] = node['nexguard']['database']['password']
ENV['PGDATABASE'] = node['nexguard']['database']['name']

unless node['nexguard']['database']['create_user'] == false
  enterprise_pg_user node['nexguard']['database']['user'] do
    superuser true
    password node['nexguard']['database']['password'] || ''
    # If the database user is the same as the main postgres user, don't create it.
    not_if do
      node['nexguard']['database']['user'] ==
        node['nexguard']['postgresql']['username']
    end
  end
end

unless node['nexguard']['database']['create_db'] == false
  enterprise_pg_database node['nexguard']['database']['name'] do
    owner node['nexguard']['database']['user']
  end
end

node['nexguard']['database']['extensions'].each do |ext, _enable|
  execute "create postgresql #{ext} extension" do
    user node['nexguard']['database']['user']
    command "echo 'CREATE EXTENSION IF NOT EXISTS #{ext}' | psql"
    not_if "echo '\\dx' | psql #{node['nexguard']['database']['name']} | grep #{ext}"
  end
end
