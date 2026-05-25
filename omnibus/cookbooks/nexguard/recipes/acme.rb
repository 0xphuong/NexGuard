# frozen_string_literal: true

# Cookbook:: nexguard
# Recipe:: acme
#
# Copyright:: 2022, NexGuard, All Rights Reserved.

include_recipe 'nexguard::config'

bin_path = "#{node['nexguard']['install_directory']}/embedded/bin"

file "#{bin_path}/acme.sh" do
  mode '0770'
  owner 'root'
  group 'root'
end

# Remove cronjob to make sure it's correctly re-created
# and remove even if acme is disabled.
execute 'ACME remove cronjob' do
  command <<~ACME
    #{bin_path}/acme.sh --uninstall-cronjob
  ACME
end

# Enable ACME if set to enabled and user-specified certs are disabled, maintains
# backwards compatibility during upgrades.
if node['nexguard']['ssl']['acme']['enabled'] && !node['nexguard']['ssl']['certificate']

  keylength = node['nexguard']['ssl']['acme']['keylength']
  server = node['nexguard']['ssl']['acme']['server']
  # We include the server in acme's home to force it to re-generate
  acme_home = "#{node['nexguard']['var_directory']}/#{server}/#{keylength}/acme"
  fqdn = URI.parse(node['nexguard']['external_url']).host
  certfile = "#{node['nexguard']['var_directory']}/ssl/acme/#{fqdn}.cert"
  keyfile = "#{node['nexguard']['var_directory']}/ssl/acme/#{fqdn}.key"
  fullchainfile = "#{node['nexguard']['var_directory']}/ssl/acme/#{fqdn}.fullchain"
  is_ecc = keylength.include? 'ec'

  directory acme_home do
    mode '0770'
    owner 'root'
    group 'root'
    recursive true
  end

  execute 'ACME initialization' do
    # Need to cwd to bin_path because ACME expects to copy itself
    cwd bin_path
    command <<~ACME
      ./acme.sh --install \
      --debug \
      --home #{acme_home} \
      --accountemail "#{node['nexguard']['ssl']['email_address']}"
    ACME
  end

  execute 'ACME registration' do
    command <<~ACME
      #{bin_path}/acme.sh --register-account \
      --home #{acme_home} \
      --server #{server} \
      --debug \
      -m #{node['nexguard']['ssl']['email_address']}
    ACME
  end

  # Pick up any nginx conf changes that may have happened during this Chef run
  execute 'Reload Nginx' do
    notifies :reload, 'component_runit_service[nginx]', :immediately
    command 'echo "reloading nginx..."'
  end

  execute 'ACME issue' do
    # Command returns 0: Cert was issued
    # Command returns 2: Skipping because renewal isn't needed
    returns [0, 2]
    command <<~ACME
      #{bin_path}/acme.sh --issue \
        --home #{acme_home} \
        --server #{server} \
        --keylength #{keylength} \
        --debug \
        -d #{URI.parse(node['nexguard']['external_url']).host} \
        -w #{node['nexguard']['var_directory']}/nginx/acme_root
    ACME
  end

  execute 'ACME install-cert' do
    command <<~ACME
      #{bin_path}/acme.sh --install-cert \
        --home #{acme_home} \
        --debug \
        -d #{fqdn} \
        #{'--ecc' if is_ecc} \
        --cert-file "#{certfile}" \
        --key-file "#{keyfile}" \
        --server #{server} \
        --fullchain-file "#{fullchainfile}" \
        --reloadcmd "nexguard-ctl hup nginx"
    ACME
  end
end
