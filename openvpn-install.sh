#!/bin/sh
# BusyBox ash supports "local"; everything else is POSIX sh.
# shellcheck disable=SC3043
# OpenVPN server installer for OpenWrt 22.03 and newer.
# https://github.com/Lenvix/openwrt-openvpn-install
#
# First run: installs and configures an OpenVPN server and creates the first
# client. Next runs: menu to add / revoke clients or remove everything.
# Every router change is made through UCI with section names owned by this
# script, so removal deletes exactly what was added.
#
# Headless mode: see README.md (AUTO_INSTALL=y, MENU_OPTION=1..4, ...).

# ---------------------------------------------------------------------------
# Names and paths owned by this script (one place for every name)
# ---------------------------------------------------------------------------
TAG=ovpninstall                       # ownership tag of every UCI section the script adds
META="openvpn.${TAG}_meta"            # installer state (type $TAG, not an openvpn instance)
INSTANCE=openvpninstall               # openvpn instance name (asked at install)
CONFIG_MODE=uci                       # uci: options as UCI settings (LuCI form); file: text .ovpn
CLIENT_DIR=/root                      # where client .ovpn files go (asked at install)
VPN_IF=vpn                            # network interface + firewall zone (asked at install)
TUN_DEV=tun0                          # first free tunN (chosen at install)
FW_ZONE="firewall.${TAG}_zone"
FW_RULE="firewall.${TAG}_rule"
FW_FWD_PREFIX="firewall.${TAG}_fwd_"  # + lan / wan
DNSMASQ="dhcp.@dnsmasq[0]"
SYSUPGRADE_CONF=/etc/sysupgrade.conf

# everything that derives from the instance name
set_paths() {
	SRV="openvpn.$INSTANCE"
	BASE_DIR=/etc/openvpn/$INSTANCE
	PKI_DIR=$BASE_DIR/pki
	SRV_DIR=$BASE_DIR/server
	VARS_FILE=$BASE_DIR/easyrsa-vars
	OVPN_FILE=/etc/openvpn/$INSTANCE.ovpn # text-mode config (LuCI's own location)
}
set_paths

CERT_DAYS=3650                        # CA, server cert, CRL; also the max for clients
NEED_FREE_KB=8192
PKG_OPENVPN=openvpn-openssl
PKG_EASYRSA=openvpn-easy-rsa
PKG_LUCI=luci-app-openvpn

# ---------------------------------------------------------------------------
# Output and prompting
# ---------------------------------------------------------------------------
say() { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# HEADLESS=1 when answers come from the environment (set once in main).
HEADLESS=0

# nth N item1 item2 ... -> prints itemN
nth() {
	local n="$1"
	shift "$n"
	printf '%s\n' "$1"
}

in_range() { # MIN MAX VALUE
	case "$3" in '' | *[!0-9]*) return 1 ;; esac
	[ "$3" -ge "$1" ] && [ "$3" -le "$2" ]
}

is_yes_no() { case "$1" in [yY] | [nN] | [yY][eE][sS] | [nN][oO]) return 0 ;; esac; return 1; }
is_yes() { case "$1" in [yY] | [yY][eE][sS]) return 0 ;; esac; return 1; }

# ask VAR QUESTION DEFAULT VALIDATOR...
# A preset VAR (environment) is validated and kept. Headless runs fall back
# to DEFAULT; interactive runs re-ask until VALIDATOR accepts the answer.
ask() {
	local var="$1" question="$2" default="$3" value
	shift 3
	eval "value=\${$var:-}"
	if [ -n "$value" ]; then
		"$@" "$value" && return 0
		[ "$HEADLESS" = 1 ] && die "invalid value for $var: '$value'"
		warn "invalid value for $var: '$value'"
	elif [ "$HEADLESS" = 1 ]; then
		"$@" "$default" || die "$var must be set (no usable default)"
		eval "$var=\$default"
		return 0
	fi
	while :; do
		if [ -n "$default" ]; then
			printf '%s [%s]: ' "$question" "$default"
		else
			printf '%s: ' "$question"
		fi
		read -r value || die "input closed"
		[ -z "$value" ] && value="$default"
		"$@" "$value" && break
		say "Invalid answer, please try again."
	done
	eval "$var=\$value"
}

# ask_choice VAR QUESTION DEFAULT_NUMBER option1 option2 ...
ask_choice() {
	local var="$1" question="$2" default="$3" i=1 opt
	shift 3
	if [ "$HEADLESS" != 1 ]; then
		say "$question"
		for opt in "$@"; do
			say "   $i) $opt"
			i=$((i + 1))
		done
	fi
	ask "$var" "Select an option [1-$#]" "$default" in_range 1 "$#"
}

ask_yes_no() { # VAR QUESTION DEFAULT(y|n)
	ask "$1" "$2 (y/n)" "$3" is_yes_no
}

# ---------------------------------------------------------------------------
# Validators for answers
# ---------------------------------------------------------------------------
is_ipv4() {
	case "$1" in '' | *[!0-9.]* | .* | *. | *..*) return 1 ;; esac
	local IFS=. octet
	# shellcheck disable=SC2086
	set -- $1
	[ $# -eq 4 ] || return 1
	for octet; do
		case "$octet" in 0?*) return 1 ;; esac
		[ "${#octet}" -le 3 ] && [ "$octet" -le 255 ] || return 1
	done
}

is_optional_ipv4() { [ -z "$1" ] || is_ipv4 "$1"; }

is_hostname() {
	case "$1" in '' | *[!A-Za-z0-9.-]* | .* | -* | *..*) return 1 ;; esac
	case "$1" in *[A-Za-z]*) return 0 ;; esac # all-digit names are bad IPs
	return 1
}

is_endpoint() { is_ipv4 "$1" || is_hostname "$1"; }
is_port() { in_range 1 65535 "$1"; }

is_client_name() {
	case "$1" in '' | *[!A-Za-z0-9_-]*) return 1 ;; esac
	[ "${#1}" -le 64 ]
}

client_exists() {
	[ -e "$PKI_DIR/issued/$1.crt" ] || [ "$1" = "$(meta_get server_cn)" ]
}

# ---------------------------------------------------------------------------
# IPv4 arithmetic (needs 64-bit shell arithmetic, as BusyBox ash has)
# ---------------------------------------------------------------------------
ip_to_int() {
	local IFS=.
	# shellcheck disable=SC2086
	set -- $1
	echo $((($1 << 24) | ($2 << 16) | ($3 << 8) | $4))
}

int_to_ip() {
	echo "$((($1 >> 24) & 255)).$((($1 >> 16) & 255)).$((($1 >> 8) & 255)).$(($1 & 255))"
}

prefix_mask() { # PREFIX -> mask as integer
	[ "$1" -eq 0 ] && { echo 0; return; }
	echo $(((0xFFFFFFFF << (32 - $1)) & 0xFFFFFFFF))
}

is_cidr() {
	case "$1" in */*) ;; *) return 1 ;; esac
	is_ipv4 "${1%/*}" && in_range 0 32 "${1#*/}"
}

cidrs_overlap() { # A/p B/p
	local p="${1#*/}" m
	[ "${2#*/}" -lt "$p" ] && p="${2#*/}"
	m=$(prefix_mask "$p")
	[ $(($(ip_to_int "${1%/*}") & m)) -eq $(($(ip_to_int "${2%/*}") & m)) ]
}

cidr_network() { # A/p -> network address
	int_to_ip $(($(ip_to_int "${1%/*}") & $(prefix_mask "${1#*/}")))
}

overlaps_any() { # CIDR "LIST OF CIDRS"
	local c
	for c in $2; do
		cidrs_overlap "$1" "$c" && return 0
	done
	return 1
}

PRIVATE_CIDRS="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16"
NON_PUBLIC_CIDRS="$PRIVATE_CIDRS 100.64.0.0/10 169.254.0.0/16 127.0.0.0/8 0.0.0.0/8"

is_public_ipv4() { is_ipv4 "$1" && ! overlaps_any "$1/32" "$NON_PUBLIC_CIDRS"; }

# ---------------------------------------------------------------------------
# Router facts
# ---------------------------------------------------------------------------
# Plain `ip -4 addr` / `ip -4 route` output (BusyBox ip: no -br / -j).
# Reads lines, prints valid CIDRs (bare addresses become /32).
to_cidrs() {
	local c
	while read -r c; do
		case "$c" in */*) ;; *) c="$c/32" ;; esac
		is_cidr "$c" && echo "$c"
	done
}

addr_cidrs() { # ip -4 addr output on stdin
	awk '$1 == "inet" { print $2; if ($3 == "peer") print $4 }' | to_cidrs
}

route_cidrs() { # ip -4 route output on stdin
	awk '{ d = $1
	       if (d ~ /^(unicast|unreachable|blackhole|prohibit|throw)$/) d = $2
	       if (d != "default") print d }' | to_cidrs
}

router_cidrs() {
	{
		ip -4 addr 2>/dev/null | addr_cidrs
		ip -4 route 2>/dev/null | route_cidrs
	} | sort -u
}

# VPN subnets are always /24, given as the network address a.b.c.0
is_free_vpn_subnet() { # NET USED_CIDRS
	is_ipv4 "$1" || return 1
	case "$1" in *.0) ;; *) return 1 ;; esac
	overlaps_any "$1/32" "$PRIVATE_CIDRS" || return 1
	! overlaps_any "$1/24" "$2"
}

first_free_subnet() { # USED_CIDRS
	local b=8 c
	while [ "$b" -le 255 ]; do
		c=0
		while [ "$c" -le 255 ]; do
			is_free_vpn_subnet "10.$b.$c.0" "$1" && { echo "10.$b.$c.0"; return 0; }
			c=$((c + 1))
		done
		b=$((b + 1))
	done
	return 1
}

vpn_gateway() { echo "${1%.0}.1"; } # a.b.c.0 -> a.b.c.1

wan_ipv4() {
	ubus call network.interface.wan status 2>/dev/null |
		jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null
}

detect_public_ipv4() {
	local ip
	ip=$(wget -qO- -T 10 https://api.ipify.org 2>/dev/null)
	is_ipv4 "$ip" && echo "$ip"
}

lan_cidrs() {
	local dev
	dev=$(ubus call network.interface.lan status 2>/dev/null | jsonfilter -e '@.l3_device' 2>/dev/null)
	[ -n "$dev" ] || return 0
	ip -4 addr show dev "$dev" 2>/dev/null | addr_cidrs
}

firewall_zone_exists() { # ZONE_NAME
	local s
	for s in $(uci -q show firewall | sed -n 's/^firewall\.\([^.=]*\)=zone$/\1/p'); do
		[ "$(uci -q get "firewall.$s.name")" = "$1" ] && return 0
	done
	return 1
}

# ---------------------------------------------------------------------------
# Routing modes: one table, everything else derives from it
# ---------------------------------------------------------------------------
route_mode_label() {
	case "$1" in
	1) echo "All traffic: internet and LAN through the VPN" ;;
	2) echo "Internet only (wan): internet through the VPN, no LAN access" ;;
	3) echo "LAN only: LAN through the VPN, client internet stays direct" ;;
	4) echo "No forwarding: clients reach only the router itself" ;;
	esac
}

route_forward_dests() { # MODE -> firewall zones vpn may forward to
	case "$1" in 1) echo "lan wan" ;; 2) echo "wan" ;; 3) echo "lan" ;; 4) echo "" ;; esac
}

route_redirects_gateway() { [ "$1" = 1 ] || [ "$1" = 2 ]; }

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
check_root() { [ "$(id -u)" = 0 ] || die "run this script as root"; }

check_openwrt() {
	[ -f /etc/openwrt_release ] || die "this script only runs on OpenWrt"
	local DISTRIB_RELEASE major
	# shellcheck disable=SC1091
	. /etc/openwrt_release
	major="${DISTRIB_RELEASE%%.*}"
	case "$major" in
	'' | *[!0-9]*) warn "unknown OpenWrt release '$DISTRIB_RELEASE', continuing" ;;
	*) [ "$major" -ge 22 ] || die "OpenWrt 22.03 or newer is required (found $DISTRIB_RELEASE)" ;;
	esac
}

check_clock() {
	[ "$(date +%Y)" -ge 2024 ] && return 0
	warn "the router clock looks unset ($(date)). Certificates are dated from it;"
	warn "fix the time (System > System > Sync with browser, or NTP) before clients connect."
}

detect_pkg_manager() {
	if command -v apk >/dev/null 2>&1; then
		PKG_MGR=apk
	elif command -v opkg >/dev/null 2>&1; then
		PKG_MGR=opkg
	else
		die "neither apk nor opkg found"
	fi
}

pkg_update() { case "$PKG_MGR" in apk) apk update ;; opkg) opkg update ;; esac; }
pkg_install() { case "$PKG_MGR" in apk) apk add "$@" ;; opkg) opkg install "$@" ;; esac; }
pkg_remove() { case "$PKG_MGR" in apk) apk del "$@" ;; opkg) opkg remove --autoremove "$@" ;; esac; }
pkg_installed() {
	case "$PKG_MGR" in
	apk) apk info -e "$1" >/dev/null 2>&1 ;;
	opkg) opkg status "$1" 2>/dev/null | grep -q '^Status:.* installed' ;;
	esac
}

luci_present() { [ -d /www/luci-static ]; }

# LuCI keeps a menu cache; drop it so the OpenVPN page appears/disappears at once.
refresh_luci() {
	luci_present || return 0
	rm -f /tmp/luci-indexcache /tmp/luci-indexcache.*
	svc rpcd reload
}

find_easyrsa() {
	local f
	for f in /usr/bin/easyrsa /usr/lib/easy-rsa/easyrsa /etc/easy-rsa/easyrsa; do
		[ -x "$f" ] && { echo "$f"; return 0; }
	done
	return 1
}

missing_packages() {
	[ -x /usr/sbin/openvpn ] || echo "$PKG_OPENVPN"
	find_easyrsa >/dev/null || echo "$PKG_EASYRSA"
	if is_yes "${INSTALL_LUCI:-n}" && ! pkg_installed "$PKG_LUCI"; then echo "$PKG_LUCI"; fi
}

free_kb() {
	local dir=/
	grep -q ' /overlay ' /proc/mounts && dir=/overlay
	df -k "$dir" | awk 'END { print $(NF-2) }'
}

check_free_space() {
	local kb
	kb=$(free_kb)
	case "$kb" in '' | *[!0-9]*) warn "could not read free flash space"; return 0 ;; esac
	[ "$kb" -ge "$NEED_FREE_KB" ] || die "not enough free flash: ${kb} KB free, about ${NEED_FREE_KB} KB needed"
}

# The interface name is used for the network interface and its firewall
# zone; it must belong to nobody else. (fw3 limited zone names to 11 chars.)
is_iface_name() {
	case "$1" in '' | *[!A-Za-z0-9_]* | [0-9]*) return 1 ;; esac
	[ "${#1}" -le 11 ]
}
iface_taken() { uci -q get "network.$1" >/dev/null || firewall_zone_exists "$1"; }
is_free_iface_name() { is_iface_name "$1" && ! iface_taken "$1"; }

first_free_iface() {
	local name=vpn i=1
	while iface_taken "$name"; do
		name="vpn$i"
		i=$((i + 1))
	done
	echo "$name"
}

tun_taken() {
	ip link show "$1" >/dev/null 2>&1 && return 0
	uci -q show openvpn | grep -q "\.dev='$1'" && return 0
	grep -qs "^dev[[:space:]][[:space:]]*$1[[:space:]]*\$" /etc/openvpn/*.conf /etc/openvpn/*.ovpn
}

# Instance name: UCI section openvpn.<name>, /etc/openvpn/<name>/ and
# /etc/openvpn/<name>.ovpn - none of them may exist yet.
is_instance_name() {
	case "$1" in '' | *[!A-Za-z0-9_]* | [0-9]*) return 1 ;; esac
	[ "${#1}" -le 32 ] && [ "$1" != "${TAG}_meta" ]
}
instance_taken() {
	uci -q get "openvpn.$1" >/dev/null || [ -e "/etc/openvpn/$1" ] ||
		[ -e "/etc/openvpn/$1.ovpn" ] || [ -e "/etc/openvpn/$1.conf" ]
}
is_free_instance_name() { is_instance_name "$1" && ! instance_taken "$1"; }

is_dir_path() { # absolute, plain characters, not / itself
	case "$1" in /*) ;; *) return 1 ;; esac
	case "$1" in / | *[!A-Za-z0-9._/-]* | *//* | */../* | */..) return 1 ;; esac
	return 0
}

first_free_tun() {
	local i=0
	while tun_taken "tun$i"; do i=$((i + 1)); done
	echo "tun$i"
}

check_zones() {
	firewall_zone_exists wan || warn "no firewall zone 'wan'; the port rule and internet forwarding will not work"
	firewall_zone_exists lan || warn "no firewall zone 'lan'; LAN forwarding will not work"
}

# ---------------------------------------------------------------------------
# UCI helpers and state
# ---------------------------------------------------------------------------
uset() { uci -q set "$1=$2" || die "uci set $1 failed"; }
uadd() { uci -q add_list "$1=$2" || die "uci add_list $1 failed"; }
meta_get() { uci -q get "$META.$1"; }
is_installed() { uci -q get "$META" >/dev/null; }

# names chosen at install time (defaults only matter for a broken state)
load_state() {
	INSTANCE=$(meta_get instance)
	CONFIG_MODE=$(meta_get config_mode)
	CLIENT_DIR=$(meta_get client_dir)
	VPN_IF=$(meta_get vpn_if)
	TUN_DEV=$(meta_get tun_dev)
	[ -n "$INSTANCE" ] || INSTANCE=openvpninstall
	[ -n "$CONFIG_MODE" ] || CONFIG_MODE=uci
	[ -n "$CLIENT_DIR" ] || CLIENT_DIR=/root
	[ -n "$VPN_IF" ] || VPN_IF=vpn
	[ -n "$TUN_DEV" ] || TUN_DEV=tun0
	set_paths
}

# ---------------------------------------------------------------------------
# Install questions -> plain variables
# ---------------------------------------------------------------------------
ask_instance() {
	[ -n "${INSTANCE_NAME:-}" ] ||
		say "Name of the OpenVPN instance (shown in LuCI; keys go to /etc/openvpn/<name>/)."
	ask INSTANCE_NAME "Instance name (letters, digits and _)" openvpninstall is_free_instance_name
	INSTANCE=$INSTANCE_NAME
	set_paths
}

ask_config_mode() {
	ask_choice CONFIG_FORMAT "How should the server configuration be stored?" 1 \
		"LuCI form: every option is a UCI setting (VPN > OpenVPN > Edit)" \
		"Text file: $OVPN_FILE, edited as text in LuCI"
	CONFIG_MODE=$(nth "$CONFIG_FORMAT" uci file)
}

ask_client_dir() {
	ask CLIENT_FILES_DIR "Directory for client .ovpn files" /root is_dir_path
	CLIENT_DIR=${CLIENT_FILES_DIR%/}
}

ask_endpoint() {
	local def=""
	if [ -z "${ENDPOINT:-}" ]; then
		say "Public IPv4 address or hostname clients will connect to."
		def=$(wan_ipv4)
		if ! is_public_ipv4 "$def"; then
			warn "the WAN address '${def:-none}' is not public (private or CGNAT);"
			warn "clients need a public IP or a DDNS hostname that reaches this router."
			def=""
			ask_yes_no DETECT_PUBLIC_IP "Detect the public IP via api.ipify.org?" y
			is_yes "$DETECT_PUBLIC_IP" && def=$(detect_public_ipv4)
		fi
	fi
	ask ENDPOINT "Public address or hostname" "$def" is_endpoint
}

ask_port() {
	# a preset PORT alone means "custom port"
	[ -n "${PORT:-}" ] && [ -z "${PORT_CHOICE:-}" ] && PORT_CHOICE=2
	ask_choice PORT_CHOICE "Which port should OpenVPN listen on?" 1 \
		"Default: 1194" "Custom" "Random [49152-65535]"
	case "$PORT_CHOICE" in
	1) PORT=1194 ;;
	2) ask PORT "Custom port [1-65535]" 1194 is_port ;;
	3) PORT=$(awk 'BEGIN { srand(); print 49152 + int(rand() * 16384) }')
	   say "Random port: $PORT" ;;
	esac
}

ask_protocol() {
	ask_choice PROTOCOL_CHOICE "Which protocol should OpenVPN use? UDP is faster." 1 "UDP" "TCP"
	PROTOCOL=$(nth "$PROTOCOL_CHOICE" udp tcp)
}

ask_route_mode() {
	ask_choice ROUTE_MODE "What should VPN clients be able to reach?" 1 \
		"$(route_mode_label 1)" "$(route_mode_label 2)" "$(route_mode_label 3)" "$(route_mode_label 4)"
}

ask_subnet() {
	local used auto
	used=$(router_cidrs)
	auto=$(first_free_subnet "$used") || die "no free 10.x.y.0/24 subnet found"
	[ -n "${VPN_SUBNET:-}" ] || say "VPN subnet (/24, must not overlap networks on the router). Free subnet found: $auto"
	ask VPN_SUBNET "VPN subnet network address" "$auto" is_free_vpn_subnet_arg "$used"
	VPN_SUBNET="${VPN_SUBNET%/24}"
}

# argument order adapter for ask(): validator gets USED first, value last
is_free_vpn_subnet_arg() { is_free_vpn_subnet "${2%/24}" "$1"; }

ask_iface() {
	local def
	def=$(first_free_iface)
	if [ -z "${VPN_IFACE:-}" ]; then
		say "Name of the VPN network interface and its firewall zone"
		say "(letters, digits and _, not starting with a digit, up to 11 characters)."
	fi
	ask VPN_IFACE "Interface name" "$def" is_free_iface_name
	VPN_IF=$VPN_IFACE
	TUN_DEV=$(first_free_tun)
}

ask_dns() {
	ask_choice DNS "Which DNS server should clients use?" 1 \
		"Router (dnsmasq on the VPN gateway address)" "Cloudflare (1.1.1.1)" "Quad9 (9.9.9.9)" \
		"Google (8.8.8.8)" "AdGuard DNS (94.140.14.14)" "Custom"
	if [ "$DNS" = 6 ]; then
		ask DNS1 "Primary DNS server" "" is_ipv4
		ask DNS2 "Secondary DNS server (empty for none)" "" is_optional_ipv4
	fi
}

dns_servers() { # CHOICE GATEWAY
	case "$1" in
	1) echo "$2" ;;
	2) echo "1.1.1.1 1.0.0.1" ;;
	3) echo "9.9.9.9 149.112.112.112" ;;
	4) echo "8.8.8.8 8.8.4.4" ;;
	5) echo "94.140.14.14 94.140.15.15" ;;
	6) echo "$DNS1 ${DNS2:-}" ;;
	esac
}

ask_compression() {
	say "Compression is not recommended (VORACLE attack) and is being removed from OpenVPN."
	ask_yes_no COMPRESSION_ENABLED "Enable compression?" n
	COMPRESS=""
	is_yes "$COMPRESSION_ENABLED" || return 0
	ask_choice COMPRESSION_CHOICE "Which compression algorithm?" 1 "LZ4-v2" "LZ4" "LZO"
	COMPRESS=$(nth "$COMPRESSION_CHOICE" lz4-v2 lz4 lzo)
}

ask_encryption() {
	say "Defaults: ECDSA prime256v1 certificates, AES-128-GCM, SHA256, tls-crypt."
	ask_yes_no CUSTOMIZE_ENC "Customize encryption settings?" n
	if ! is_yes "$CUSTOMIZE_ENC"; then
		CIPHER=AES-128-GCM CERT_ALGO=ec CERT_CURVE=prime256v1 RSA_KEY_SIZE=2048
		HMAC_ALG=SHA256 TLS_SIG=tls-crypt
		return 0
	fi
	ask_choice CIPHER_CHOICE "Data channel cipher:" 1 \
		"AES-128-GCM (recommended)" "AES-192-GCM" "AES-256-GCM" "CHACHA20-POLY1305"
	CIPHER=$(nth "$CIPHER_CHOICE" AES-128-GCM AES-192-GCM AES-256-GCM CHACHA20-POLY1305)
	ask_choice CERT_TYPE "Certificate type:" 1 "ECDSA (recommended)" "RSA"
	CERT_ALGO=$(nth "$CERT_TYPE" ec rsa) CERT_CURVE=prime256v1 RSA_KEY_SIZE=2048
	if [ "$CERT_ALGO" = ec ]; then
		ask_choice CERT_CURVE_CHOICE "Certificate curve:" 1 "prime256v1 (recommended)" "secp384r1" "secp521r1"
		CERT_CURVE=$(nth "$CERT_CURVE_CHOICE" prime256v1 secp384r1 secp521r1)
	else
		ask_choice RSA_KEY_SIZE_CHOICE "RSA key size:" 1 "2048 bits (recommended)" "3072 bits" "4096 bits"
		RSA_KEY_SIZE=$(nth "$RSA_KEY_SIZE_CHOICE" 2048 3072 4096)
	fi
	ask_choice HMAC_ALG_CHOICE "HMAC digest for the control channel:" 1 "SHA-256 (recommended)" "SHA-384" "SHA-512"
	HMAC_ALG=$(nth "$HMAC_ALG_CHOICE" SHA256 SHA384 SHA512)
	ask_choice TLS_SIG_CHOICE "Control channel protection:" 1 \
		"tls-crypt (authenticate and encrypt, recommended)" "tls-auth (authenticate only)"
	TLS_SIG=$(nth "$TLS_SIG_CHOICE" tls-crypt tls-auth)
}

ask_luci() {
	local def=n
	luci_present && def=y
	pkg_installed "$PKG_LUCI" && { INSTALL_LUCI=y; return 0; }
	[ "$def" = n ] && [ -z "${INSTALL_LUCI:-}" ] && say "LuCI is not installed; $PKG_LUCI would pull it in."
	ask_yes_no INSTALL_LUCI "Install the LuCI web page for OpenVPN ($PKG_LUCI)?" "$def"
}

is_days() { in_range 1 "$CERT_DAYS" "$1"; }

ask_client_days_default() {
	ask CLIENT_DAYS_DEFAULT "Default certificate lifetime for new clients, in days [1-$CERT_DAYS]" \
		"$CERT_DAYS" is_days
}

ask_client() { # DEFAULT_NAME
	local days_def
	while :; do
		ask CLIENT "Client name (letters, digits, _ and -)" "$1" is_client_name
		client_exists "$CLIENT" || break
		[ "$HEADLESS" = 1 ] && die "client '$CLIENT' already exists"
		say "Client '$CLIENT' already exists, choose another name."
		CLIENT=""
	done
	days_def=${CLIENT_DAYS_DEFAULT:-$(meta_get client_days)}
	is_days "$days_def" || days_def=$CERT_DAYS
	ask CLIENT_DAYS "Certificate lifetime for '$CLIENT', in days [1-$CERT_DAYS]" "$days_def" is_days
	ask_choice PASS "Protect the client key with a password?" 1 \
		"Passwordless client" "Password-protected client"
	[ "$PASS" = 2 ] && [ "$HEADLESS" = 1 ] && die "PASS=2 needs an interactive terminal"
	return 0
}

ask_install_questions() {
	say "Welcome to the OpenVPN installer for OpenWrt."
	say "Press Enter to accept the default shown in [brackets]."
	say ""
	ask_instance
	ask_config_mode
	ask_endpoint
	ask_port
	ask_protocol
	ask_route_mode
	ask_subnet
	ask_iface
	ask_dns
	ask_compression
	ask_encryption
	ask_luci
	ask_client_dir
	ask_client_days_default
	ask_client client
}

show_install_summary() {
	say ""
	say "Instance:    $INSTANCE (keys in $BASE_DIR/)"
	if [ "$CONFIG_MODE" = file ]; then say "Config:      text file $OVPN_FILE"; else say "Config:      LuCI form (UCI settings)"; fi
	say "Endpoint:    $ENDPOINT:$PORT/$PROTOCOL"
	say "Routing:     $(route_mode_label "$ROUTE_MODE")"
	say "VPN subnet:  $VPN_SUBNET/24 (router: $(vpn_gateway "$VPN_SUBNET"))"
	say "Interface:   $VPN_IF (firewall zone $VPN_IF, device $TUN_DEV)"
	say "Client DNS:  $(dns_servers "$DNS" "$(vpn_gateway "$VPN_SUBNET")")"
	if [ "$CERT_ALGO" = ec ]; then
		say "Encryption:  $CIPHER, $HMAC_ALG, $TLS_SIG, ECDSA $CERT_CURVE certificates"
	else
		say "Encryption:  $CIPHER, $HMAC_ALG, $TLS_SIG, RSA $RSA_KEY_SIZE-bit certificates"
	fi
	say "Compression: ${COMPRESS:-disabled}"
	if is_yes "$INSTALL_LUCI"; then say "LuCI page:   yes ($PKG_LUCI)"; else say "LuCI page:   no"; fi
	say "Client files: $CLIENT_DIR/<name>.ovpn"
	say "Client certs: $CLIENT_DAYS_DEFAULT days by default"
	say "First client: $CLIENT ($CLIENT_DAYS days)"
	say ""
}

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------
install_packages() {
	local missing
	missing=$(missing_packages)
	INSTALLED_PKGS="$missing"
	[ -n "$missing" ] || return 0
	check_free_space
	say "Installing packages: $missing"
	pkg_update || die "package list update failed (check the internet connection)"
	# shellcheck disable=SC2086
	pkg_install $missing || die "package installation failed"
}

check_runtime() {
	[ -x /usr/sbin/openvpn ] || die "/usr/sbin/openvpn not found after installation"
	[ -x /etc/init.d/openvpn ] || die "/etc/init.d/openvpn not found (this OpenWrt build manages OpenVPN differently)"
	EASYRSA_BIN=$(find_easyrsa) || die "easyrsa not found after installation"
}

openvpn_service_enabled() { [ -x /etc/init.d/openvpn ] && /etc/init.d/openvpn enabled; }

# ---------------------------------------------------------------------------
# PKI (easy-rsa 3.0.8 .. 3.2.x: only common options)
# ---------------------------------------------------------------------------
easyrsa_home() { # directory holding openssl-easyrsa.cnf and x509-types
	if [ -e /etc/easy-rsa/openssl-easyrsa.cnf ]; then
		echo /etc/easy-rsa
	else
		dirname "$(readlink -f "$EASYRSA_BIN")"
	fi
}

run_easyrsa() {
	(
		cd "$BASE_DIR" || exit 1
		umask 077
		export EASYRSA EASYRSA_PKI EASYRSA_VARS_FILE EASYRSA_TEMP_DIR EASYRSA_ALGO \
			EASYRSA_CURVE EASYRSA_KEY_SIZE EASYRSA_CA_EXPIRE EASYRSA_CERT_EXPIRE EASYRSA_CRL_DAYS
		EASYRSA=$(easyrsa_home)
		# easy-rsa 3.1+ in batch mode uses EASYRSA_REQ_CN as the CN of EVERY
		# request, so it is set for the CA only; other certs take the name argument.
		unset EASYRSA_REQ_CN
		if [ "$1" = build-ca ]; then
			EASYRSA_REQ_CN=${CA_CN:-$TAG}
			export EASYRSA_REQ_CN
		fi
		EASYRSA_PKI=$PKI_DIR
		EASYRSA_VARS_FILE=$VARS_FILE
		EASYRSA_TEMP_DIR=/tmp
		EASYRSA_ALGO=$(meta_get cert_algo)
		EASYRSA_CURVE=$(meta_get cert_curve)
		EASYRSA_KEY_SIZE=$(meta_get rsa_size)
		EASYRSA_CA_EXPIRE=$CERT_DAYS
		EASYRSA_CERT_EXPIRE=${CERT_EXPIRE_DAYS:-$CERT_DAYS}
		EASYRSA_CRL_DAYS=$CERT_DAYS
		"$EASYRSA_BIN" --batch "$@"
	) || die "easyrsa $1 failed"
}

random_id() { tr -d '-' </proc/sys/kernel/random/uuid | cut -c1-16; }

publish_crl() {
	cp "$PKI_DIR/crl.pem" "$SRV_DIR/crl.pem" || die "cannot copy the CRL"
	chmod 644 "$SRV_DIR/crl.pem" # read by openvpn after it drops to 'nobody'
}

build_server_pki() {
	local server_cn
	server_cn=$(meta_get server_cn)
	mkdir -p "$BASE_DIR" "$SRV_DIR"
	chmod 755 "$BASE_DIR" "$SRV_DIR"
	echo "# easy-rsa vars for $TAG (settings come from the environment)" >"$VARS_FILE"
	CA_CN="ca_$(random_id)"
	run_easyrsa init-pki
	run_easyrsa build-ca nopass
	run_easyrsa build-server-full "$server_cn" nopass
	run_easyrsa gen-crl
	if ! cp "$PKI_DIR/ca.crt" "$SRV_DIR/ca.crt" ||
		! cp "$PKI_DIR/issued/$server_cn.crt" "$SRV_DIR/server.crt" ||
		! cp "$PKI_DIR/private/$server_cn.key" "$SRV_DIR/server.key"; then
		die "cannot copy the server certificates"
	fi
	openvpn --genkey secret "$SRV_DIR/tls.key" || die "cannot generate the TLS key"
	chmod 600 "$SRV_DIR/server.key" "$SRV_DIR/tls.key"
	publish_crl
}

# names of client certificates in the PKI index; STATUS: V (valid) or . (any)
pki_clients() {
	local server_cn
	server_cn=$(meta_get server_cn)
	[ -f "$PKI_DIR/index.txt" ] || return 0
	awk -F'/CN=' -v st="$1" -v srv="$server_cn" \
		'($1 ~ ("^" st)) { split($2, a, "/"); if (a[1] != srv) print a[1] }' "$PKI_DIR/index.txt"
}

# ---------------------------------------------------------------------------
# Client configuration file
# ---------------------------------------------------------------------------
pem_block() { # TAG FILE -> inline block with only the PEM part of FILE
	printf '<%s>\n' "$1"
	awk '/-----BEGIN/,/-----END/' "$2"
	printf '</%s>\n' "$1"
}

client_config() { # NAME
	local name="$1" cipher compress
	cipher=$(meta_get cipher)
	compress=$(meta_get compress)
	cat <<EOF
client
dev tun
proto $(meta_get proto)
remote $(meta_get endpoint) $(meta_get port)
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
verify-x509-name $(meta_get server_cn) name
auth $(meta_get auth)
auth-nocache
cipher $cipher
data-ciphers $cipher
tls-client
tls-version-min 1.2
verb 3
EOF
	if [ -n "$compress" ]; then
		echo "ignore-unknown-option allow-compression"
		echo "allow-compression yes"
		echo "compress $compress"
	fi
	if route_redirects_gateway "$(meta_get route_mode)"; then
		echo "ignore-unknown-option block-outside-dns"
		echo "setenv opt block-outside-dns"
	fi
	pem_block ca "$SRV_DIR/ca.crt"
	pem_block cert "$PKI_DIR/issued/$name.crt"
	pem_block key "$PKI_DIR/private/$name.key"
	if [ "$(meta_get tls_sig)" = tls-crypt ]; then
		pem_block tls-crypt "$SRV_DIR/tls.key"
	else
		echo "key-direction 1"
		pem_block tls-auth "$SRV_DIR/tls.key"
	fi
}

add_client() { # NAME PASS(1|2) DAYS
	local name="$1" file="$CLIENT_DIR/$1.ovpn" CERT_EXPIRE_DAYS="$3"
	mkdir -p "$CLIENT_DIR" || die "cannot create $CLIENT_DIR"
	# leftovers of an interrupted earlier attempt (no certificate was issued)
	rm -f "$PKI_DIR/reqs/$name.req" "$PKI_DIR/private/$name.key" "$PKI_DIR/inline/private/$name.inline"
	if [ "$2" = 2 ]; then
		say "You will be asked for the client key password."
		run_easyrsa build-client-full "$name"
	else
		run_easyrsa build-client-full "$name" nopass
	fi
	(umask 077 && client_config "$name" >"$file") || die "cannot write $file"
	say "Client '$name' added. Configuration file: $file"
	say "Certificate valid until: $(openssl x509 -noout -enddate -in "$PKI_DIR/issued/$name.crt" 2>/dev/null | cut -d= -f2)"
	say "Download it (e.g. scp root@router:$file .) and import it into the OpenVPN client."
}

revoke_client() { # NAME
	run_easyrsa revoke "$1"
	run_easyrsa gen-crl
	publish_crl
	rm -f "$CLIENT_DIR/$1.ovpn"
	say "Certificate of '$1' revoked; the server refuses it from the next handshake."
}

# ---------------------------------------------------------------------------
# Router configuration (UCI)
# ---------------------------------------------------------------------------
write_meta() {
	local p
	uset "$META" "$TAG"
	uset "$META.instance" "$INSTANCE"
	uset "$META.config_mode" "$CONFIG_MODE"
	uset "$META.client_dir" "$CLIENT_DIR"
	# client template (the same in both config modes)
	uset "$META.proto" "$PROTOCOL"
	uset "$META.port" "$PORT"
	uset "$META.auth" "$HMAC_ALG"
	uset "$META.cipher" "$CIPHER"
	uset "$META.tls_sig" "$TLS_SIG"
	[ -n "$COMPRESS" ] && uset "$META.compress" "$COMPRESS"
	uset "$META.endpoint" "$ENDPOINT"
	uset "$META.route_mode" "$ROUTE_MODE"
	uset "$META.client_days" "$CLIENT_DAYS_DEFAULT"
	uset "$META.vpn_if" "$VPN_IF"
	uset "$META.tun_dev" "$TUN_DEV"
	uset "$META.server_cn" "server_$(random_id)"
	uset "$META.cert_algo" "$CERT_ALGO"
	uset "$META.cert_curve" "$CERT_CURVE"
	uset "$META.rsa_size" "$RSA_KEY_SIZE"
	uset "$META.openvpn_was_enabled" "$OPENVPN_WAS_ENABLED"
	for p in $INSTALLED_PKGS; do uadd "$META.installed_pkg" "$p"; done
}

# Server options are listed once (server_options); opt / opt_flag / opt_list
# write each one as a UCI setting or as a line of the text config file.
# KEY is the UCI spelling (tls_crypt); the file uses openvpn's (tls-crypt).
opt_line() { printf '%s\n' "$*" >>"$OVPN_FILE.tmp"; }
opt_key() { echo "$1" | tr _ -; }

opt() { # KEY VALUE
	if [ "$CONFIG_MODE" = file ]; then opt_line "$(opt_key "$1") $2"; else uset "$SRV.$1" "$2"; fi
}
opt_flag() { # KEY
	if [ "$CONFIG_MODE" = file ]; then opt_line "$(opt_key "$1")"; else uset "$SRV.$1" 1; fi
}
opt_list() { # KEY VALUE
	if [ "$CONFIG_MODE" != file ]; then
		uadd "$SRV.$1" "$2"
	elif [ "$1" = push ]; then
		opt_line "push \"$2\""
	else
		opt_line "$(opt_key "$1") $2"
	fi
}

server_push() {
	local gw net dns cidr
	gw=$(vpn_gateway "$VPN_SUBNET")
	if route_redirects_gateway "$ROUTE_MODE"; then
		opt_list push "redirect-gateway def1 bypass-dhcp"
	fi
	if [ "$ROUTE_MODE" = 3 ]; then
		[ -n "$(lan_cidrs)" ] || warn "no IPv4 address on interface 'lan'; no LAN route is pushed"
		for cidr in $(lan_cidrs); do
			net=$(cidr_network "$cidr")
			opt_list push "route $net $(int_to_ip "$(prefix_mask "${cidr#*/}")")"
		done
	fi
	for dns in $(dns_servers "$DNS" "$gw"); do
		opt_list push "dhcp-option DNS $dns"
	done
}

server_options() {
	opt dev "$TUN_DEV"
	opt dev_type tun
	opt proto "$PROTOCOL"
	opt port "$PORT"
	opt server "$VPN_SUBNET 255.255.255.0"
	opt topology subnet
	opt keepalive "10 120"
	opt_flag persist_key
	opt_flag persist_tun
	opt user nobody
	opt group nogroup
	opt ca "$SRV_DIR/ca.crt"
	opt cert "$SRV_DIR/server.crt"
	opt key "$SRV_DIR/server.key"
	opt dh none
	opt crl_verify "$SRV_DIR/crl.pem"
	if [ "$TLS_SIG" = tls-crypt ]; then
		opt tls_crypt "$SRV_DIR/tls.key"
	else
		opt tls_auth "$SRV_DIR/tls.key 0"
	fi
	opt auth "$HMAC_ALG"
	opt_list data_ciphers "$CIPHER"
	opt data_ciphers_fallback "$CIPHER"
	opt tls_version_min 1.2
	opt verb 3
	[ "$PROTOCOL" = udp ] && opt explicit_exit_notify 1
	if [ -n "$COMPRESS" ]; then
		opt compress "$COMPRESS"
		opt allow_compression yes
	fi
	server_push
}

write_server() {
	uset "$SRV" openvpn
	uset "$SRV.enabled" 1
	if [ "$CONFIG_MODE" = file ]; then
		echo "# OpenVPN server '$INSTANCE', written by openvpn-install; edit freely" >"$OVPN_FILE.tmp" ||
			die "cannot write $OVPN_FILE"
		server_options
		chmod 600 "$OVPN_FILE.tmp"
		mv "$OVPN_FILE.tmp" "$OVPN_FILE" || die "cannot write $OVPN_FILE"
		uset "$SRV.config" "$OVPN_FILE"
	else
		server_options
	fi
}

write_network() {
	uset "network.$VPN_IF" interface
	uset "network.$VPN_IF.proto" none
	uset "network.$VPN_IF.device" "$TUN_DEV"
}

write_firewall() {
	local dest
	uset "$FW_ZONE" zone
	uset "$FW_ZONE.name" "$VPN_IF"
	uadd "$FW_ZONE.network" "$VPN_IF"
	uset "$FW_ZONE.input" ACCEPT
	uset "$FW_ZONE.output" ACCEPT
	uset "$FW_ZONE.forward" REJECT
	uset "$FW_RULE" rule
	uset "$FW_RULE.name" "Allow-OpenVPN-$INSTANCE"
	uset "$FW_RULE.src" wan
	uset "$FW_RULE.proto" "$PROTOCOL"
	uset "$FW_RULE.dest_port" "$PORT"
	uset "$FW_RULE.target" ACCEPT
	for dest in $(route_forward_dests "$ROUTE_MODE"); do
		uset "$FW_FWD_PREFIX$dest" forwarding
		uset "$FW_FWD_PREFIX$dest.src" "$VPN_IF"
		uset "$FW_FWD_PREFIX$dest.dest" "$dest"
	done
}

# dnsmasq answers on tun0 by default (localservice accepts the local VPN
# subnet). Only an explicit 'interface' list would shut it out.
write_dnsmasq() {
	[ "$DNS" = 1 ] || return 0
	uci -q get "$DNSMASQ" >/dev/null || { warn "no dnsmasq section; router DNS will not work"; return 0; }
	if uci -q get "$DNSMASQ.notinterface" | grep -qw -e "$VPN_IF" -e "$TUN_DEV"; then
		warn "dnsmasq is told to ignore '$VPN_IF'; clients will get no DNS answers"
	fi
	local ifaces
	ifaces=$(uci -q get "$DNSMASQ.interface")
	[ -n "$ifaces" ] || return 0
	echo "$ifaces" | grep -qw "$VPN_IF" && return 0
	uadd "$DNSMASQ.interface" "$VPN_IF"
	uset "$META.dnsmasq_iface_added" 1
	DNSMASQ_RESTART=1
}

UCI_CONFIGS="openvpn network firewall dhcp"
DNSMASQ_RESTART=0

svc() { # SERVICE ACTION; silently skips services that are not installed
	[ -x "/etc/init.d/$1" ] && "/etc/init.d/$1" "$2"
}

commit_and_reload() {
	local c
	for c in $UCI_CONFIGS; do uci commit "$c"; done
	svc network reload
	svc firewall reload
	[ "$DNSMASQ_RESTART" = 1 ] && svc dnsmasq restart
	svc openvpn reload # procd adds/removes our instance, others stay untouched
	return 0
}

# keys (and the text config) survive sysupgrade
sysupgrade_lines() {
	echo "$BASE_DIR/"
	[ "$CONFIG_MODE" = file ] && echo "$OVPN_FILE"
	return 0
}

add_sysupgrade_lines() {
	local line
	touch "$SYSUPGRADE_CONF"
	for line in $(sysupgrade_lines); do
		grep -qxF "$line" "$SYSUPGRADE_CONF" || echo "$line" >>"$SYSUPGRADE_CONF"
	done
}

remove_sysupgrade_lines() {
	[ -f "$SYSUPGRADE_CONF" ] || return 0
	grep -vxF -e "$BASE_DIR/" -e "$OVPN_FILE" "$SYSUPGRADE_CONF" >"$SYSUPGRADE_CONF.tmp"
	cat "$SYSUPGRADE_CONF.tmp" >"$SYSUPGRADE_CONF" # keep the original inode/mode
	rm -f "$SYSUPGRADE_CONF.tmp"
}

# procd stops the removed instance asynchronously; wait until tun0 is gone.
wait_tun_gone() {
	local i=0
	while ip link show $TUN_DEV >/dev/null 2>&1; do
		[ "$i" -ge 15 ] && { warn "$TUN_DEV is still present after 15 s"; return 0; }
		sleep 1
		i=$((i + 1))
	done
}

# Idempotent: removes only what this script names, tolerates partial installs.
remove_router_changes() {
	local dest
	[ "$(meta_get dnsmasq_iface_added)" = 1 ] && uci -q del_list "$DNSMASQ.interface=$VPN_IF" && DNSMASQ_RESTART=1
	for dest in lan wan; do uci -q delete "$FW_FWD_PREFIX$dest"; done
	uci -q delete "$FW_RULE"
	uci -q delete "$FW_ZONE"
	[ "$(uci -q get network.$VPN_IF.device)" = "$TUN_DEV" ] && uci -q delete network.$VPN_IF
	uci -q delete "$SRV"
	uci -q delete "$META"
	commit_and_reload
	wait_tun_gone
	rm -rf "$BASE_DIR"
	rm -f "$OVPN_FILE" "$OVPN_FILE.tmp"
	remove_sysupgrade_lines
}

# ---------------------------------------------------------------------------
# Flows
# ---------------------------------------------------------------------------
cleanup_partial_install() {
	uci -q get "$META" >/dev/null || return 0
	warn "an incomplete previous installation was found; cleaning it up"
	load_state
	remove_router_changes
}

install_flow() {
	cleanup_partial_install
	check_zones
	check_clock
	ask_install_questions
	show_install_summary
	ask_yes_no APPROVE_INSTALL "Install OpenVPN with these settings?" y
	is_yes "$APPROVE_INSTALL" || die "installation cancelled"

	OPENVPN_WAS_ENABLED=0
	openvpn_service_enabled && OPENVPN_WAS_ENABLED=1
	install_packages
	check_runtime

	write_meta # build_server_pki reads the certificate settings from it
	build_server_pki
	write_server
	write_network
	write_firewall
	write_dnsmasq
	add_sysupgrade_lines
	svc openvpn enable
	commit_and_reload
	refresh_luci

	add_client "$CLIENT" "$PASS" "$CLIENT_DAYS"
	say ""
	say "OpenVPN is installed. Run this script again to add or revoke clients."
}

require_easyrsa() {
	EASYRSA_BIN=$(find_easyrsa) || die "easyrsa not found; reinstall $PKG_EASYRSA"
}

add_client_flow() {
	require_easyrsa
	ask_client ""
	add_client "$CLIENT" "$PASS" "$CLIENT_DAYS"
}

choose_client_to_revoke() {
	local clients count
	clients=$(pki_clients V)
	[ -n "$clients" ] || die "there are no clients to revoke"
	if [ -n "${CLIENT:-}" ]; then
		echo "$clients" | grep -qxF "$CLIENT" || die "no valid client named '$CLIENT'"
		return 0
	fi
	[ "$HEADLESS" = 1 ] && die "CLIENT must be set"
	count=$(echo "$clients" | awk 'END { print NR }')
	say "Select the client to revoke:"
	echo "$clients" | awk '{ printf "   %d) %s\n", NR, $0 }'
	ask CLIENT_NUMBER "Client number [1-$count]" "" in_range 1 "$count"
	CLIENT=$(echo "$clients" | sed -n "${CLIENT_NUMBER}p")
}

revoke_client_flow() {
	require_easyrsa
	choose_client_to_revoke
	revoke_client "$CLIENT"
}

remove_packages() { # PACKAGES installed by this script
	if [ -z "$1" ]; then
		say "No packages were installed by this script; none to remove."
		return 0
	fi
	ask_yes_no REMOVE_PACKAGES "Also remove the packages installed by this script ($1)?" n
	is_yes "$REMOVE_PACKAGES" || return 0
	# shellcheck disable=SC2086
	pkg_remove $1 || warn "package removal failed"
	# The package manager keeps /etc/config/openvpn because UCI rewrote it;
	# the file came with the package this script installed, so drop it too.
	case " $1 " in
	*" $PKG_OPENVPN "*) pkg_installed "$PKG_OPENVPN" || rm -f /etc/config/openvpn ;;
	esac
	refresh_luci
}

remove_client_files() {
	local name
	for name in $(pki_clients .); do rm -f "$CLIENT_DIR/$name.ovpn"; done
}

remove_flow() {
	local confirm_default=n pkgs
	[ "$HEADLESS" = 1 ] && confirm_default=y # MENU_OPTION=3 is the confirmation
	ask_yes_no REMOVE_CONFIRM "Remove OpenVPN, its configuration, keys and client files?" "$confirm_default"
	is_yes "$REMOVE_CONFIRM" || die "removal cancelled"
	pkgs=$(meta_get installed_pkg) # read before the state section is deleted
	[ "$(meta_get openvpn_was_enabled)" = 0 ] && svc openvpn disable
	remove_client_files
	remove_router_changes
	remove_packages "$pkgs"
	say "OpenVPN has been removed."
}

manage_menu() {
	load_state
	say "OpenVPN instance '$INSTANCE' is already installed (endpoint $(meta_get endpoint):$(meta_get port)/$(meta_get proto))."
	ask_choice MENU_OPTION "What do you want to do?" 4 \
		"Add a new client" "Revoke an existing client" "Remove OpenVPN" "Exit"
	case "$MENU_OPTION" in
	1) add_client_flow ;;
	2) revoke_client_flow ;;
	3) remove_flow ;;
	4) exit 0 ;;
	esac
}

main() {
	if [ "${AUTO_INSTALL:-}" = y ] || [ -n "${MENU_OPTION:-}" ]; then
		HEADLESS=1
	elif [ ! -t 0 ]; then
		die "no terminal: download the script and run it, or use AUTO_INSTALL=y / MENU_OPTION"
	fi
	check_root
	check_openwrt
	detect_pkg_manager
	if is_installed; then
		manage_menu
	elif [ "$HEADLESS" = 1 ] && [ "${AUTO_INSTALL:-}" != y ]; then
		die "OpenVPN is not installed yet; use AUTO_INSTALL=y to install headlessly"
	else
		install_flow
	fi
}

# OPENVPN_INSTALL_SOURCED=1 loads the functions without running (for tests).
[ "${OPENVPN_INSTALL_SOURCED:-}" = 1 ] || main "$@"
