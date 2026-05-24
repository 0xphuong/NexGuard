# Tạo chain 'postrouting' trong bảng 'nexguard'
sudo nft add chain inet nexguard postrouting { type nat hook postrouting priority srcnat\; policy accept\; }

# Thêm quy tắc NAT masquerade cho IPv4
sudo nft add rule inet nexguard postrouting oifname "eth0" meta nfproto ipv4 masquerade persistent

# Thêm quy tắc NAT masquerade cho IPv6
sudo nft add rule inet nexguard postrouting oifname "eth0" meta nfproto ipv6 masquerade persistent


# Xóa chain postrouting
nft delete chain inet nexguard postrouting

ip route add 10.0.22.0/24 via 172.25.0.100 dev br-ea32c601032b
ip route add 10.0.22.0/24 via 172.25.0.100 dev br-5048022b941f


# UPDATE 20240704
nft delete chain inet nexguard postrouting
# NAT cho DEV
# Tạo chain 'postrouting' trong bảng 'nexguard'
nft add chain inet nexguard postrouting { type nat hook postrouting priority srcnat\; policy accept\; }
# Thêm quy tắc NAT masquerade chỉ khi đích là subnet 10.5.67.0/24 cho IPv4
nft add rule inet nexguard postrouting ip daddr 10.5.67.0/24 oifname "eth0" meta nfproto ipv4 masquerade persistent
nft add rule inet nexguard postrouting ip daddr 10.9.68.0/24 oifname "eth0" meta nfproto ipv4 masquerade persistent
nft add rule inet nexguard postrouting ip daddr 10.114.8.0/24 oifname "eth0" meta nfproto ipv4 masquerade persistent
nft add rule inet nexguard postrouting ip daddr 10.112.8.0/24 oifname "eth0" meta nfproto ipv4 masquerade persistent
# ifconfig.me
nft add rule inet nexguard postrouting ip daddr 34.160.0.0/16 oifname "eth0" meta nfproto ipv4 masquerade persistent
# 7gt
nft add rule inet nexguard postrouting ip daddr 45.60.35.0/24 oifname "eth0" meta nfproto ipv4 masquerade persistent

nft add rule inet nexguard postrouting ip daddr 61.28.229.6/32 oifname "eth0" meta nfproto ipv4 masquerade persistent

################################################################
# UPDATE 20250704
ip route add 10.0.22.0/24 via 172.25.0.100 dev br-ea32c601032b

# Xóa chain cũ
nft delete chain inet nexguard postrouting

# Tạo chain 'postrouting' trong bảng 'nexguard'
nft add chain inet nexguard postrouting { type nat hook postrouting priority srcnat\; policy accept\; }

# MẶC ĐỊNH: NAT masquerade cho tất cả traffic IPv4 qua eth0
nft add rule inet nexguard postrouting oifname "eth0" meta nfproto ipv4 masquerade persistent
nft add rule inet nexguard postrouting oifname "eth0" meta nfproto ipv6 masquerade persistent

# NGOẠI LỆ: Forward (không NAT) cho các subnet cụ thể
# Các rule này sẽ được đặt TRƯỚC rule mặc định để có độ ưu tiên cao hơn

# Xóa rule mặc định trước khi thêm các rule ngoại lệ
nft flush chain inet nexguard postrouting

# Thêm các rule FORWARD (không NAT) cho các subnet cụ thể
# Rule này sẽ accept và không xử lý thêm (return) cho các subnet được chỉ định
nft add rule inet nexguard postrouting ip daddr 10.0.0.0/16 oifname "eth0" meta nfproto ipv4 return
nft add rule inet nexguard postrouting ip daddr 10.2.0.0/16 oifname "eth0" meta nfproto ipv4 return
nft add rule inet nexguard postrouting ip daddr 10.8.0.0/16 oifname "eth0" meta nfproto ipv4 return

# Rule MẶC ĐỊNH: NAT masquerade cho tất cả traffic IPv4 còn lại qua eth0
nft add rule inet nexguard postrouting oifname "eth0" meta nfproto ipv4 masquerade persistent
nft add rule inet nexguard postrouting oifname "eth0" meta nfproto ipv6 masquerade persistent


# clamp-mss-to-pmtu
nft add table inet filter
nft add chain inet filter forward { type filter hook forward priority 0\; policy accept\; }


nft add rule inet filter forward tcp flags syn tcp option maxseg size set clamp to pmtu
nft add rule inet filter forward tcp flags syn tcp option maxseg size set clamp to path-mtu
nft add rule inet filter forward tcp flags syn tcp option maxseg size set 1410

# Áp dụng cho tất cả kết nối TCP SYN đi qua VyOS / Linux host
nft add rule inet filter forward tcp flags syn tcp option maxseg size set 1410
nft add rule inet filter output  tcp flags syn tcp option maxseg size set 1410
