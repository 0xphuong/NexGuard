#!/bin/bash
NEXGUARD_DEV_V4='172.28.0.0/16'
NEXGUARD_DEV_V6='fcff:3990:3990::/64'
TABLE=333444

sudo ip -4 rule del from $NEXGUARD_DEV_V4 table $TABLE
sudo ip -4 route flush table $TABLE
sudo ip -6 rule del from $NEXGUARD_DEV_V6 table $TABLE
sudo ip -6 route flush table $TABLE
