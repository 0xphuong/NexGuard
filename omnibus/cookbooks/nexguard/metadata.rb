# frozen_string_literal: true

name 'nexguard'
maintainer 'NexGuard'
maintainer_email 'infra@binhphuong.io.vn'
license 'Apache-2.0'
description 'Installs/Configures nexguard'
version '0.0.1'
chef_version '>= 16.0'

depends 'enterprise'
depends 'runit'
depends 'line'

# The `issues_url` points to the location where issues for this cookbook are
# tracked.  A `View Issues` link will be displayed on this cookbook's page when
# uploaded to a Supermarket.
#
# issues_url 'https://github.com/<insert_org_here>/nexguard/issues'

# The `source_url` points to the development repository for this cookbook.  A
# `View Source` link will be displayed on this cookbook's page when uploaded to
# a Supermarket.
#
# source_url 'https://github.com/<insert_org_here>/nexguard'
