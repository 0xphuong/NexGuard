# frozen_string_literal: true

# # NexGuard configuration

require 'etc'

#
# Attributes here will be applied to configure the application and the services
# it uses.
#
# Most of the attributes in this file are things you will not need to ever
# touch, but they are here in case you need them.
#
# A `nexguard-ctl reconfigure` should pick up any changes made here.
#
# If /etc/nexguard/nexguard.json exists, its attributes will be loaded
# after these, so if you have that file with the contents:
#
#     { "postgresql": { "enable": false } }
#
# for example, it will set the node['nexguard']['postgresql']['enabled'] attribute to false.

# ## Top-level attributes
#
# These are used by the other items below. More app-specific top-level
# attributes are further down in this file.

# ## External URL (REQUIRED)
#
# This will be used to generate URLs for outbound emails, websocket connections
# and OAuth redirects.
# and host headers that nginx passes along. If using a custom path, scheme, or port,
# you may want to change this, e.g. http://nexguard.example.com:1234/custom-root-prefix/
default['nexguard']['external_url'] = "https://#{node['fqdn'] || node['hostname']}"

# Email for the primary admin user.
default['nexguard']['admin_email'] = 'nexguard@localhost'

# The maximum number of devices a user can have.
# Max: 100
# Default: 10
default['nexguard']['max_devices_per_user'] = 10

# Allow users to create (and download) their own devices. Set to false
# if you only want administrators to create and manage devices.
default['nexguard']['allow_unprivileged_device_management'] = true

# Allow users to configure the following device fields when creating a device:
# use_site_allowed_ips
# allowed_ips
# use_site_dns
# dns
# use_site_endpoint
# endpoint
# use_site_mtu
# mtu
# use_site_persistent_keepalive
# persistent_keepalive
# ipv4
# ipv6
#
# If you only want users to modify the name and description for new devices,
# disable this.
default['nexguard']['allow_unprivileged_device_configuration'] = true

default['nexguard']['config_directory'] = '/etc/nexguard'
default['nexguard']['install_directory'] = '/opt/nexguard'
default['nexguard']['app_directory'] = "#{node['nexguard']['install_directory']}/embedded/service/nexguard"
default['nexguard']['log_directory'] = '/var/log/nexguard'
default['nexguard']['var_directory'] = '/var/opt/nexguard'
default['nexguard']['user'] = 'nexguard'
default['nexguard']['group'] = 'nexguard'

# The outgoing interface name.
# This is where tunneled traffic will exit the WireGuard tunnel.
# If set to nil, this is will be set to the interface for the machine's
# default route.
default['nexguard']['egress_interface'] = nil

# Whether to use OpenSSL FIPS mode across NexGuard. Default disabled.
default['nexguard']['fips_enabled'] = nil

# ## Global Logging Settings
#
# Enable or disable logging. Set this to false to disable NexGuard logs.
default['nexguard']['logging']['enabled'] = true

# ## Enterprise
#
# The "enterprise" cookbook provides recipes and resources we can use for this
# app.

default['enterprise']['name'] = 'nexguard'

# Enterprise uses install_path internally, but we use install_directory because
# it's more consistent. Alias it here so both work.
default['nexguard']['install_path'] = node['nexguard']['install_directory']

# An identifier used in /etc/inittab (default is 'SUP'). Needs to be a unique
# (for the file) sequence of 1-4 characters.
default['nexguard']['sysvinit_id'] = 'SUP'

# ## Authentication

# These settings control authentication-related aspects of NexGuard.
# For more information, see https://docs.nexguard.binhphuong.io.vn/user-guides/authentication/
#
# When local email/password authentication is used, users must be created by an Administrator
# before they can sign in.
#
# When SSO authentication methods are used, users are automatically added to NexGuard
# when logging in for the first time via the SSO provider.
#
# Users are uniquely identified by their email address, and may sign in via multiple providers
# if configured.

# Local email/password authentication is enabled by default
default['nexguard']['authentication']['local']['enabled'] = true

# OIDC Authentication
#
# NexGuard can disable a user's VPN if there's any error detected trying
 # to refresh their access_token. This is verified to work for Google, Okta, and
 # Azure SSO and is used to automatically disconnect a user's VPN if they're removed
 # from the OIDC provider. Leave this disabled if your OIDC provider
 # has issues refreshing access tokens as it could unexpectedly interrupt a
 # user's VPN session.
default['nexguard']['authentication']['disable_vpn_on_oidc_error'] = false

# Any OpenID Connect provider can be used here.
# Multiple OIDC configs can be added to the same NexGuard instance.
# This is an example using Google and Okta as an SSO identity provider.
# default['nexguard']['authentication']['oidc'] = [
#   {
#     discovery_document_uri: "https://accounts.google.com/.well-known/openid-configuration",
#     client_id: "<GOOGLE_CLIENT_ID>",
#     client_secret: "<GOOGLE_CLIENT_SECRET>",
#     redirect_uri: "https://nexguard.example.com/auth/oidc/google/callback/",
#     response_type: "code",
#     scope: "openid email profile",
#     label: "Google",
#     auto_create_users: true
#   },
#   okta: {
#     discovery_document_uri: "https://<OKTA_DOMAIN>/.well-known/openid-configuration",
#     client_id: "<OKTA_CLIENT_ID>",
#     client_secret: "<OKTA_CLIENT_SECRET>",
#     redirect_uri: "https://nexguard.example.com/auth/oidc/okta/callback/",
#     response_type: "code",
#     scope: "openid email profile offline_access",
#     label: "Okta",
#     auto_create_users: true
#   }
# ]
default['nexguard']['authentication']['oidc'] = []

# SAML Authentication providers
#
# Example adding an OKTA provider:
#
# default['nexguard']['authentication']['saml'] = [
#   {
#     "auto_create_users": false,
#     "base_url": "https://saml",
#     "id": "okta",
#     "label": "okta",
#     "metadata": "<?xml version="1.0"?>...",
#     "sign_metadata": false,
#     "sign_requests": false,
#     "signed_assertion_in_resp": false,
#     "signed_envelopes_in_resp": false
#   }
# ]
default['nexguard']['authentication']['saml'] = []

# ## Custom Reverse Proxy
#
# An array of IPs that NexGuard will trust as reverse proxies.
#
# Read more here:
# https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/X-Forwarded-For#selecting_an_ip_address
#
# By default the following IPs are included:
# * IPv4: 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16
# * IPv6: ::1/128, fc00::/7
#
# If any client requests will actually be coming from these private IPs, add them to
# default['nexguard']['phoenix']['private_clients'] below instead of here.
#
# If set to false NexGuard will assume that it is not running behind a proxy
default['nexguard']['phoenix']['external_trusted_proxies'] = []

# An array of IPs that NexGuard will assume are clients, and thus, not a trusted
# proxy for the purpose of determining the client's IP. By default the bundled
# See more here: https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/X-Forwarded-For#selecting_an_ip_address
# This will supersede any proxy configured manually or by default by
# default['nexguard']['external_trusted_proxies']
default['nexguard']['phoenix']['private_clients'] = []

# ## Nginx

# These attributes control NexGuard-specific portions of the Nginx
# configuration and the virtual host for the NexGuard Phoenix app.
default['nexguard']['nginx']['enabled'] = true
default['nexguard']['nginx']['ssl_port'] = 443
default['nexguard']['nginx']['directory'] = "#{node['nexguard']['var_directory']}/nginx/etc"
default['nexguard']['nginx']['log_directory'] = "#{node['nexguard']['log_directory']}/nginx"
default['nexguard']['nginx']['log_rotation']['file_maxbytes'] = 104_857_600
default['nexguard']['nginx']['log_rotation']['num_to_keep'] = 10
default['nexguard']['nginx']['log_x_forwarded_for'] = true

# HSTS Header settings
default['nexguard']['nginx']['hsts_header']['enabled'] = true
default['nexguard']['nginx']['hsts_header']['include_subdomains'] = true
default['nexguard']['nginx']['hsts_header']['max_age'] = 31536000

# Permit nginx to listen for IPv6 connections in addition to IPv4
default['nexguard']['nginx']['ipv6'] = true

# Redirect to the FQDN
default['nexguard']['nginx']['redirect_to_canonical'] = false

# Controls nginx caching, used to cache some endpoints
default['nexguard']['nginx']['cache']['enabled'] = false
default['nexguard']['nginx']['cache']['directory'] = "#{node['nexguard']['var_directory']}/nginx/cache"

# These attributes control the main nginx.conf, including the events and http
# contexts.
#
# These will be copied to the top-level nginx namespace and used in a
# template from the community nginx cookbook
# (https://github.com/miketheman/nginx/blob/master/templates/default/nginx.conf.erb)
default['nexguard']['nginx']['user'] = node['nexguard']['user']
default['nexguard']['nginx']['group'] = node['nexguard']['group']
default['nexguard']['nginx']['dir'] = node['nexguard']['nginx']['directory']
default['nexguard']['nginx']['log_dir'] = node['nexguard']['nginx']['log_directory']
default['nexguard']['nginx']['pid'] = "#{node['nexguard']['nginx']['directory']}/nginx.pid"
default['nexguard']['nginx']['daemon_disable'] = true
default['nexguard']['nginx']['gzip'] = 'on'
default['nexguard']['nginx']['gzip_static'] = 'off'
default['nexguard']['nginx']['gzip_http_version'] = '1.0'
default['nexguard']['nginx']['gzip_comp_level'] = '2'
default['nexguard']['nginx']['gzip_proxied'] = 'any'
default['nexguard']['nginx']['gzip_vary'] = 'off'
default['nexguard']['nginx']['gzip_buffers'] = nil
default['nexguard']['nginx']['gzip_types'] = %w[
  text/plain
  text/css
  application/x-javascript
  text/xml
  application/xml
  application/rss+xml
  application/atom+xml
  text/javascript
  application/javascript
  application/json
]
default['nexguard']['nginx']['gzip_min_length'] = 1000
default['nexguard']['nginx']['gzip_disable'] = 'MSIE [1-6]\.'
default['nexguard']['nginx']['keepalive'] = 'on'
default['nexguard']['nginx']['keepalive_timeout'] = 65
default['nexguard']['nginx']['worker_processes'] = node['cpu'] && node['cpu']['total'] ? node['cpu']['total'] : 1
default['nexguard']['nginx']['worker_connections'] = 1024
default['nexguard']['nginx']['worker_rlimit_nofile'] = nil
default['nexguard']['nginx']['multi_accept'] = true
default['nexguard']['nginx']['event'] = 'epoll'
default['nexguard']['nginx']['server_tokens'] = nil
default['nexguard']['nginx']['server_names_hash_bucket_size'] = 64
default['nexguard']['nginx']['sendfile'] = 'on'
default['nexguard']['nginx']['access_log_options'] = nil
default['nexguard']['nginx']['error_log_options'] = nil
default['nexguard']['nginx']['disable_access_log'] = false
default['nexguard']['nginx']['types_hash_max_size'] = 2048
default['nexguard']['nginx']['types_hash_bucket_size'] = 64
default['nexguard']['nginx']['proxy_read_timeout'] = nil
default['nexguard']['nginx']['client_body_buffer_size'] = nil
default['nexguard']['nginx']['client_max_body_size'] = '250m'
default['nexguard']['nginx']['default']['modules'] = []

# Nginx rate limiting configuration.
# Note that requests are also rate limited by the upstream Phoenix application.
default['nexguard']['nginx']['enable_rate_limiting'] = true
default['nexguard']['nginx']['rate_limiting_zone_name'] = 'nexguard'
default['nexguard']['nginx']['rate_limiting_backoff'] = '10m'
default['nexguard']['nginx']['rate_limit'] = '10r/s'

# ## Postgres

# ### Use the bundled Postgres instance (default, recommended):
#

default['nexguard']['postgresql']['enabled'] = true
default['nexguard']['postgresql']['username'] = node['nexguard']['user']
default['nexguard']['postgresql']['data_directory'] = "#{node['nexguard']['var_directory']}/postgresql/13.3/data"

# ### Using an external Postgres database
#
# Disable the provided Postgres instance and connect to your own:
#
# default['nexguard']['postgresql']['enabled'] = false
# default['nexguard']['database']['user'] = 'my_db_user_name'
# default['nexguard']['database']['name'] = 'my_db_name''
# default['nexguard']['database']['host'] = 'my.db.server.address'
# default['nexguard']['database']['port'] = 5432
#
# Further database configuration options can be found below

# ### Logs
default['nexguard']['postgresql']['log_directory'] = "#{node['nexguard']['log_directory']}/postgresql"
default['nexguard']['postgresql']['log_rotation']['file_maxbytes'] = 104_857_600
default['nexguard']['postgresql']['log_rotation']['num_to_keep'] = 10

# ### Postgres Settings
default['nexguard']['postgresql']['checkpoint_completion_target'] = 0.5
default['nexguard']['postgresql']['checkpoint_segments'] = 3
default['nexguard']['postgresql']['checkpoint_timeout'] = '5min'
default['nexguard']['postgresql']['checkpoint_warning'] = '30s'
default['nexguard']['postgresql']['effective_cache_size'] = '128MB'
default['nexguard']['postgresql']['listen_address'] = '127.0.0.1'
default['nexguard']['postgresql']['max_connections'] = 350
default['nexguard']['postgresql']['md5_auth_cidr_addresses'] = ['127.0.0.1/32', '::1/128']
default['nexguard']['postgresql']['port'] = 15_432
default['nexguard']['postgresql']['shared_buffers'] = "#{(node['memory']['total'].to_i / 4) / 1024}MB"
default['nexguard']['postgresql']['shmmax'] = 17_179_869_184
default['nexguard']['postgresql']['shmall'] = 4_194_304
default['nexguard']['postgresql']['work_mem'] = '8MB'

# ## Common Database Settings
#
# The settings below configure how NexGuard connects to and uses your database.
# At this time only Postgres (and Postgres-compatible) databases are supported.
default['nexguard']['database']['user'] = node['nexguard']['postgresql']['username']
default['nexguard']['database']['name'] = 'nexguard'
default['nexguard']['database']['host'] = node['nexguard']['postgresql']['listen_address']
default['nexguard']['database']['port'] = node['nexguard']['postgresql']['port']
default['nexguard']['database']['ssl'] = false

# SSL opts to pass to Erlang's SSL module. See a full listing at https://www.erlang.org/doc/man/ssl.html
# NexGuard supports the following subset:
# {
#   verify: :verify_peer, # or :verify_none
#   cacerts: "...",       # The DER-encoded trusted certificates. Overrides :cacertfile if specified.
#   cacertfile: "/path/to/cert.pem", # Path to a file containing PEM-encoded CA certificates.
#   versions: ["tlsv1.1", "tlsv1.2", "tlsv1.3"], # Array of TLS versions to enable
# }
default['nexguard']['database']['ssl_opts'] = {}

# DB Connection Parameters to pass to the Postgrex driver. If you're unsure, leave this blank.
default['nexguard']['database']['parameters'] = {}

default['nexguard']['database']['pool'] = [10, Etc.nprocessors].max
default['nexguard']['database']['extensions'] = { 'plpgsql' => true, 'pg_trgm' => true }

# Create the DB user. Set this to false if the user already exists.
default['nexguard']['database']['create_user'] = true

# Create the DB. Set this to false if the database already exists.
default['nexguard']['database']['create_db'] = true

# Uncomment to specify a database password. Not usually needed if using the bundled Postgresql.
# default['nexguard']['database']['password'] = 'change_me'

# ## Phoenix

# ### The Phoenix web app for NexGuard
default['nexguard']['phoenix']['enabled'] = true
default['nexguard']['phoenix']['listen_address'] = '127.0.0.1'
default['nexguard']['phoenix']['port'] = 13_000
default['nexguard']['phoenix']['log_directory'] = "#{node['nexguard']['log_directory']}/phoenix"
default['nexguard']['phoenix']['log_rotation']['file_maxbytes'] = 104_857_600
default['nexguard']['phoenix']['log_rotation']['num_to_keep'] = 10

# Toggle bringing down the web app for NexGuard if a crash loop is detected.
# When set to true, the web app will be brought down after 5 crashes.
# When set to false, this will allow the web app to crash indefinitely.
default['nexguard']['phoenix']['crash_detection']['enabled'] = true

# ## WireGuard

# ### Interface Management
# Enable management of the WireGuard interface itself. Set this to false if you
# want to manually create your WireGuard interface and manage its interface properties.
default['nexguard']['wireguard']['enabled'] = true
default['nexguard']['wireguard']['log_directory'] = "#{node['nexguard']['log_directory']}/wireguard"
default['nexguard']['wireguard']['log_rotation']['file_maxbytes'] = 104_857_600
default['nexguard']['wireguard']['log_rotation']['num_to_keep'] = 10

# The WireGuard interface name NexGuard will apply configuration settings to.
default['nexguard']['wireguard']['interface_name'] = 'wg-nexguard'

# WireGuard listen port
default['nexguard']['wireguard']['port'] = 51_820

# WireGuard interface MTU
default['nexguard']['wireguard']['mtu'] = 1280

# WireGuard endpoint
# By default, the public IP address of this server is used as the Endpoint
# field for generating Device configs. Override this if you wish to change.
default['nexguard']['wireguard']['endpoint'] = nil

# Default AllowedIPs to use for generated device configs specified as a comma-separated
# list of IPv4 / IPv6 CIDRs.
# Default is to tunnel all IPv4 and IPv6 traffic with '0.0.0.0/0, ::/0'
default['nexguard']['wireguard']['allowed_ips'] = '0.0.0.0/0, ::/0'

# Default DNS servers to use for generated device configs.
# Defaults to CloudFlare's public DNS. Set to nil to omit DNS from generated
# device configurations.
default['nexguard']['wireguard']['dns'] = '1.1.1.1, 1.0.0.1'

# Default PersistentKeepalive setting to use for generated device configs.
# See https://www.wireguard.com/quickstart/#nat-and-firewall-traversal-persistence
# Set to 0 or nil to disable. Default 0.
default['nexguard']['wireguard']['persistent_keepalive'] = 0

# Enable or disable IPv4 connectivity in your WireGuard network. Default enabled.
default['nexguard']['wireguard']['ipv4']['enabled'] = true

# Enable or disable SNAT/Masquerade for packets leaving the WireGuard ipv4 tunnel. Default true.
default['nexguard']['wireguard']['ipv4']['masquerade'] = true

# The CIDR-formatted IPv4 network to use for your WireGuard network. Default 10.3.2.0/24.
default['nexguard']['wireguard']['ipv4']['network'] = '10.3.2.0/24'

# The IPv4 address to assign to your WireGuard interface. Must be an address
# contained within the WireGuard network specific above. Default 10.3.2.1.
default['nexguard']['wireguard']['ipv4']['address'] = '10.3.2.1'

# Enable or disable IPv6 connectivity in your WireGuard network. Default enabled.
default['nexguard']['wireguard']['ipv6']['enabled'] = true

# Enable or disable SNAT/Masquerade for packets leaving the WireGuard ipv6 tunnel. Default true.
default['nexguard']['wireguard']['ipv6']['masquerade'] = true

# The CIDR-formatted IPv6 network to use for your WireGuard network. Default fd00::3:2:0/120.
default['nexguard']['wireguard']['ipv6']['network'] = 'fd00::3:2:0/120'

# The IPv6 address to assign to your WireGuard interface. Must be an address
# contained within the WireGuard network specific above. Default fd00::3:2:1.
default['nexguard']['wireguard']['ipv6']['address'] = 'fd00::3:2:1'

# ## Runit

# This is missing from the enterprise cookbook
# see (https://github.com/chef-cookbooks/enterprise-chef-common/pull/17)
#
# Will be copied to the root node.runit namespace.
default['nexguard']['runit']['svlogd_bin'] = "#{node['nexguard']['install_directory']}/embedded/bin/svlogd"

# ## SSL

default['nexguard']['ssl']['directory'] = '/var/opt/nexguard/ssl'

# Email to use for self signed certs and ACME cert issuance and renewal notices.
# Defaults to default['nexguard']['admin_email'] if nil.
default['nexguard']['ssl']['email_address'] = nil

# Enable / disable ACME protocol support to auto-provision SSL certificates.
# Before turning this on, please ensure:
# 1. default['nexguard']['external_url'] includes a valid FQDN
# 2. Port 80/tcp is accessible; this is used for domain validation.
# 3. default['nexguard']['ssl']['email_address'] is set properly. This will be used for renewal notices.
default['nexguard']['ssl']['acme']['enabled'] = false

# Set the ACME server directory for ACME protocol SSL certificate issuance
# This option requires default['nexguard']['ssl']['acme']['enabled']
# You can either set one of the CA short names as explained here (https://github.com/acmesh-official/acme.sh/wiki/Server)
# or the directory URL.
# In case ACME is enabled this option will default to letsencrypt
default['nexguard']['ssl']['acme']['server'] = 'letsencrypt'
# Specify the key type and length for the cert. See more at https://github.com/acmesh-official/acme.sh#10-issue-ecc-certificates
# Allowed values are:
# * RSA: 2048, 3072, 4096, 8192
# * ECDSA(recommended): ec-256, ec-384, ec-521
default['nexguard']['ssl']['acme']['keylength'] = 'ec-256'


# Paths to the SSL certificate and key files. If these are set, ACME is automatically disabled.
# If these are nil and ACME is disabled, we will attempt to generate a self-signed certificate and use that instead.
default['nexguard']['ssl']['certificate'] = nil
default['nexguard']['ssl']['certificate_key'] = nil

# Path to the SSL dhparam file if you want to specify your own SSL DH parameters.
default['nexguard']['ssl']['ssl_dhparam'] = nil

# These are used in creating a self-signed cert if you haven't brought your own.
default['nexguard']['ssl']['country_name'] = 'US'
default['nexguard']['ssl']['state_name'] = 'CA'
default['nexguard']['ssl']['locality_name'] = 'San Francisco'
default['nexguard']['ssl']['company_name'] = 'My Company'
default['nexguard']['ssl']['organizational_unit_name'] = 'Operations'

# ### Cipher settings
#
# Based off of the Mozilla recommended cipher suite
# https://wiki.mozilla.org/Security/Server_Side_TLS#Recommended_Ciphersuite
#
# SSLV3 was removed because of the poodle attack. (https://www.openssl.org/~bodo/ssl-poodle.pdf)
#
# If your infrastructure still has requirements for the vulnerable/venerable SSLV3, you can add
# "SSLv3" to the below line.
default['nexguard']['ssl']['ciphers'] =
  'ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256:DHE-DSS-AES128-GCM-SHA256:kEDH+AESGCM:ECDHE-RSA-AES128-SHA256:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA:ECDHE-ECDSA-AES128-SHA:ECDHE-RSA-AES256-SHA384:ECDHE-ECDSA-AES256-SHA384:ECDHE-RSA-AES256-SHA:ECDHE-ECDSA-AES256-SHA:DHE-RSA-AES128-SHA256:DHE-RSA-AES128-SHA:DHE-DSS-AES128-SHA256:DHE-RSA-AES256-SHA256:DHE-DSS-AES256-SHA:DHE-RSA-AES256-SHA:AES128-GCM-SHA256:AES256-GCM-SHA384:AES128-SHA:AES256-SHA:AES:CAMELLIA:DES-CBC3-SHA:!aNULL:!eNULL:!EXPORT:!DES:!RC4:!MD5:!PSK:!aECDH:!EDH-DSS-DES-CBC3-SHA:!EDH-RSA-DES-CBC3-SHA:!KRB5-DES-CBC3-SHA'
default['nexguard']['ssl']['fips_ciphers'] = 'FIPS@STRENGTH:!aNULL:!eNULL'
default['nexguard']['ssl']['protocols'] = 'TLSv1 TLSv1.1 TLSv1.2'
default['nexguard']['ssl']['session_cache'] = 'shared:SSL:4m'
default['nexguard']['ssl']['session_timeout'] = '5m'

# ### robots.txt Settings
#
# These control the "Allow" and "Disallow" paths in /robots.txt. See
# http://www.robotstxt.org/robotstxt.html for more information. Only a single
# line for each item is supported. If a value is nil, the line will not be
# present in the file.
default['nexguard']['robots_allow'] = '/'
default['nexguard']['robots_disallow'] = nil

# ### Outbound Email Settings
# If from_email not set, the outbound email feature will be disabled (default)
default['nexguard']['outbound_email']['from'] = nil

# If provider not set, the :sendmail delivery method will be used. Using
# the sendmail delivery method requires that a working mail transfer agent
# (usually set up with a relay host) be configured on this machine.
default['nexguard']['outbound_email']['provider'] = nil

# Configure one or more providers below.
# See the Swoosh library documentation for more information on configuring adapters:
# https://github.com/swoosh/swoosh#adapters
default['nexguard']['outbound_email']['configs'] = {
  smtp: {
    # only relay is required, but you will need some combination of the rest
    relay: 'smtp.example.com',
    port: 587, # integer
    username: '', # needs to be string if present
    password: '', # needs to be string if present
    ssl: true, # boolean
    tls: :always, # always / never / if_available
    auth: :always, # always / never / if_available
    no_mx_lookup: false, # boolean
    retries: 2 # integer
  },
  mailgun: {
    # both are required
    apikey: nil,
    domain: nil # example.com
  },
  mandrill: {
    api_key: nil
  },
  sendgrid: {
    api_key: nil
  },
  post_mark: {
    api_key: nil
  },
  sendmail: {
    cmd_path: '/usr/bin/sendmail',
    cmd_args: '-N delay,failure,success'
  }
}

# ## Telemetry
#
# NexGuard relies heavily on hashed, anonymized telemetry data to help us build
# a better product for our users. This data is stored securely and is not
# shared or accessible to any third parties. Set this to false to disable.
default['nexguard']['telemetry']['enabled'] = true

# ## Diagnostics Settings

# ### Connectivity Checks
#
# By default, NexGuard periodically checks for WAN connectivity to the Internet
# by issuing a POST request with an empty body to https://ping.firez.one. This
# is used to determine the server's publicly routable IP address for populating
# device configurations and setting up firewall rules. Set this to false to
# disable.
default['nexguard']['connectivity_checks']['enabled'] = true

# Amount of time to sleep between connectivity checks, in seconds.
# Default: 3600 (1 hour). Minimum: 60 (1 minute). Maximum: 86400 (1 day).
default['nexguard']['connectivity_checks']['interval'] = 3_600

# ## Cookies settings

# Enable or disable the secure attributes for NexGuard cookies. It's highly
# recommended you leave this enabled unless you know what you're doing.
default['nexguard']['phoenix']['secure_cookies'] = true
