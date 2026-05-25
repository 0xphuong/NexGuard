#!/bin/sh

echo 'Removing NexGuard network settings...'
nexguard-ctl teardown-network

echo 'Removing all NexGuard directories...'
nexguard-ctl cleanse yes

echo 'Stopping ACME from renewing certificates...'
nexguard-ctl stop-cert-renewal

echo 'Removing nexguard package...'
if type apt-get > /dev/null; then
  DEBIAN_FRONTEND=noninteractive apt-get remove -y --purge nexguard
  rm /etc/apt/sources.list.d/nexguard-nexguard.list
  apt-get clean
  rm -rf /var/lib/apt/lists/*
  apt-get -qqy update
elif type yum > /dev/null; then
  yum remove -y nexguard
  rm /etc/yum.repos.d/nexguard-nexguard.repo
  # some distros (eg, CentOS 7) do not include this repo file
  # silence if it can't be found for removal
  rm /etc/yum.repos.d/nexguard-nexguard-source.repo 2> /dev/null
elif type zypper > /dev/null; then
  zypper --non-interactive remove -y -u nexguard
  zypper --non-interactive rr nexguard-nexguard
  zypper --non-interactive rr nexguard-nexguard-source
else
  echo 'Warning: package management tool not found; not '\
    'removing installed package. This can happen if your'\
    ' package management tool (e.g. yum, apt, etc) is no'\
    't in your $PATH. Continuing...'
fi

echo 'Removing remaining directories...'
rm -rf \
  /var/opt/nexguard \
  /var/log/nexguard \
  /etc/nexguard \
  /usr/bin/nexguard-ctl \
  /opt/nexguard

echo 'Done! NexGuard has been uninstalled.'

if tput bold; then
  bold=$(tput bold)
else
  bold=''
fi
if tput sgr0; then
  normal=$(tput sgr0)
else
  normal=''
fi

echo $bold
echo 'We rely on feedback from users to steer development.' \
  'Would you mind taking a minute to share product feedback in exchange' \
  'for some NexGuard stickers?'
echo "https://nexguard.binhphuong.io.vn/feedback?utm_source=uninstall"
echo $normal
