#!/bin/sh

ip link add dev wg-nexguard type wireguard
ip address replace dev wg-nexguard 100.64.0.1/10
ip -6 address replace dev wg-nexguard fd00::1/106
ip link set mtu 1280 up dev wg-nexguard

mix start
