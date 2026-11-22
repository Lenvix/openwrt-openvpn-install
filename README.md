# openwrt-openvpn-install

**English** | [Русский](README.ru.md)

An OpenVPN server installer for OpenWrt routers, written for OpenWrt itself:
BusyBox `ash`, `opkg` or `apk`, and configuration through UCI.

The first time you run the script, it installs the packages, builds a
certificate authority, configures the OpenVPN server, the network interface
and the firewall, and creates the first client. When you run it again, it
shows a menu:

```
1) Add a new client
2) Revoke an existing client
3) Remove OpenVPN
4) Exit
```

Each client gets a single `.ovpn` file with everything embedded (CA,
certificate, key, tls-crypt/tls-auth key), written to `<client dir>/<name>.ovpn`
(the directory is chosen at installation, `/root` by default).

## Requirements

- OpenWrt 22.03 or newer (22.03, 23.05 and 24.10 use `opkg`; 25.12 and newer use `apk`).
- Root shell on the router (SSH).
- About 6 MB of free flash for the packages (the script checks for 8 MB to be
  safe and installs only the packages that are missing).
- Internet access on the router during installation, to download packages.
- A correct router clock: certificates are dated from it. The script warns if
  the year is before 2024.

Packages used: `openvpn-openssl` and `openvpn-easy-rsa` (which pulls in
`openssl-util`), plus `luci-app-openvpn` if you ask for the web page. If another OpenVPN variant (`openvpn-mbedtls`,
`openvpn-wolfssl`) is already installed, the script uses that one.

## Usage

Download the script, then run it (OpenWrt ships `wget` through `uclient-fetch`):

```sh
wget -O openvpn-install.sh https://raw.githubusercontent.com/Lenvix/openwrt-openvpn-install/main/openvpn-install.sh && chmod +x openvpn-install.sh && ./openvpn-install.sh
```

Do not pipe the script into `sh`.
The questions need a terminal, and the script refuses to run without one
unless you use headless mode.

### Installation questions

Press Enter to accept the default shown in `[brackets]`.

1. **Instance name.** The name of the OpenVPN instance: it is shown in LuCI
   (VPN → OpenVPN), and the keys and the PKI go to `/etc/openvpn/<name>/`.
   The default is `openvpninstall`. Your own name may contain letters, digits
   and `_`, must not start with a digit, is at most 32 characters long, and
   must not exist yet as the UCI section `openvpn.<name>`, the directory
   `/etc/openvpn/<name>`, or the file `/etc/openvpn/<name>.ovpn` or
   `/etc/openvpn/<name>.conf`.
2. **How the server configuration is stored.**
   1. **LuCI form** (default): every option is a UCI setting in section
      `<name>` of `/etc/config/openvpn`, edited field by field in LuCI
      (VPN → OpenVPN → Edit).
   2. **Text file**: the options are written to `/etc/openvpn/<name>.ovpn`,
      the same place LuCI itself uses for text configurations. The UCI section
      holds only `enabled` and `option config '/etc/openvpn/<name>.ovpn'`, and
      LuCI shows the file as an editable text box. The script never rewrites
      the file after installation, so your edits are kept. Adding and revoking
      clients, however, relies on the endpoint, port, protocol and cipher
      stored at installation: if you change the port, protocol or cipher in
      the file, newly generated client files still use the old values.

   In both modes the server is started by `/etc/init.d/openvpn`.
3. **Public address.** The default is the WAN IPv4 address. If that address
   is private or CGNAT (for example 192.168.x.x or 100.64.x.x), the script
   warns you and offers to look up your public IP through `api.ipify.org`.
   You can also enter a DDNS hostname.
4. **Port.** 1194 (default), a custom port, or a random port between 49152
   and 65535.
5. **Protocol.** UDP (default) or TCP.
6. **Routing mode.** See below.
7. **VPN subnet.** A separate `/24` is created for the VPN interface. The
   script proposes the first free one, starting at `10.8.0.0/24`. A subnet is
   free when it overlaps no IPv4 address or route on the router. You can enter
   a different private `/24`, which is checked the same way. The router takes
   `.1`, clients get addresses from `.2`.
8. **VPN interface name.** One name for the OpenWrt network interface and its
   firewall zone. The default is `vpn`; if that is taken by an existing
   interface or zone, the script offers `vpn1`, `vpn2`, ... Letters, digits
   and `_`, not starting with a digit, at most 11 characters. The tun device
   is picked automatically as the first free `tunN`, so the server can live
   next to another VPN that already uses `tun0`.
9. **DNS for clients.** The router itself (dnsmasq on the VPN gateway
   address, the default), Cloudflare, Quad9, Google, AdGuard DNS, or custom
   servers.
10. **Compression.** Disabled by default. It is not recommended (VORACLE) and
   OpenVPN is removing it. You can choose LZ4-v2, LZ4 or LZO.
11. **Encryption.** By default: ECDSA `prime256v1` certificates, the
   `AES-128-GCM` data cipher, `SHA256` HMAC and `tls-crypt`. If you choose to
   customize, you can pick:
   - a cipher: AES-128/192/256-GCM or CHACHA20-POLY1305;
   - a certificate type: ECDSA with `prime256v1`, `secp384r1` or `secp521r1`, or RSA with 2048, 3072 or 4096 bits;
   - an HMAC: SHA256, SHA384 or SHA512;
   - control channel protection: `tls-crypt` or `tls-auth`.
12. **LuCI page.** Whether to install `luci-app-openvpn` (VPN → OpenVPN in
   the web interface). The default is yes when LuCI is installed and no when
   it is not, since the package would pull LuCI in. If the package is already
   there, the question is skipped.
13. **Directory for client .ovpn files.** The default is `/root`. An
   absolute path made of letters, digits, `.`, `_`, `-` and `/` (not `/`
   itself). It is created if missing and remembered for clients added later.
14. **Default client certificate lifetime.** In days, 1-3650 (default 3650).
   It is remembered and offered for every client added later.
15. **First client.** A name made of letters, digits, `_` and `-`, its
   certificate lifetime in days (the default from the previous question), and
   whether its key is protected by a password.

Every client added from the menu is asked for its own lifetime in days, with
the remembered default; after issuing, the script prints the expiry date. The
CA and the server certificate are valid for 10 years, and the CRL is renewed
for 10 years each time it is generated. A client certificate cannot be used
after the CA expires, whatever its own lifetime.

## Routing modes

| # | Mode | Firewall forwarding | Pushed to clients |
|---|------|---------------------|-------------------|
| 1 | **All traffic** (default) | vpn → lan, vpn → wan | `redirect-gateway def1 bypass-dhcp`, DNS |
| 2 | **Internet only (wan)** | vpn → wan | `redirect-gateway def1 bypass-dhcp`, DNS; no LAN access |
| 3 | **LAN only** | vpn → lan | routes to the LAN subnet(s) read from interface `lan`, DNS; client internet stays direct |
| 4 | **No forwarding** | none | DNS; clients reach only the router (VPN gateway address) |

In every mode the VPN zone accepts input, so clients can always reach the
router itself, including its DNS server.

## Headless mode

### Installation

Set `AUTO_INSTALL=y`. Every question then takes its default unless you
override it with the variable listed below.

```sh
AUTO_INSTALL=y ./openvpn-install.sh
AUTO_INSTALL=y ENDPOINT=vpn.example.org PROTOCOL_CHOICE=2 PORT=443 ROUTE_MODE=2 CLIENT=laptop ./openvpn-install.sh
```

| Variable | Values | Default |
|----------|--------|---------|
| `APPROVE_INSTALL` | `y` / `n` | `y` |
| `INSTANCE_NAME` | instance name `[A-Za-z_][A-Za-z0-9_]*`, up to 32 chars, not in use | `openvpninstall` |
| `CONFIG_FORMAT` | `1` LuCI form (UCI settings), `2` text file `/etc/openvpn/<instance>.ovpn` | `1` |
| `ENDPOINT` | public IPv4 or hostname | WAN IPv4 if public, otherwise looked up through api.ipify.org |
| `DETECT_PUBLIC_IP` | `y` / `n` (look up the public IP when the WAN address is private) | `y` |
| `PORT_CHOICE` | `1` 1194, `2` custom (`PORT`), `3` random | `1` (`2` if `PORT` is set) |
| `PORT` | 1-65535 | 1194 |
| `PROTOCOL_CHOICE` | `1` UDP, `2` TCP | `1` |
| `ROUTE_MODE` | `1` all traffic, `2` internet only, `3` LAN only, `4` no forwarding | `1` |
| `VPN_SUBNET` | private `/24` network address, e.g. `10.9.0.0` | first free from `10.8.0.0` |
| `VPN_IFACE` | interface and firewall zone name `[A-Za-z_][A-Za-z0-9_]*`, up to 11 chars, not in use | first free of `vpn`, `vpn1`, ... |
| `DNS` | `1` router, `2` Cloudflare, `3` Quad9, `4` Google, `5` AdGuard, `6` custom | `1` |
| `DNS1`, `DNS2` | IPv4 addresses for `DNS=6` (`DNS2` optional) | none |
| `COMPRESSION_ENABLED` | `y` / `n` | `n` |
| `COMPRESSION_CHOICE` | `1` lz4-v2, `2` lz4, `3` lzo | `1` |
| `CUSTOMIZE_ENC` | `y` / `n` | `n` |
| `CIPHER_CHOICE` | `1` AES-128-GCM, `2` AES-192-GCM, `3` AES-256-GCM, `4` CHACHA20-POLY1305 | `1` |
| `CERT_TYPE` | `1` ECDSA, `2` RSA | `1` |
| `CERT_CURVE_CHOICE` | `1` prime256v1, `2` secp384r1, `3` secp521r1 | `1` |
| `RSA_KEY_SIZE_CHOICE` | `1` 2048, `2` 3072, `3` 4096 | `1` |
| `HMAC_ALG_CHOICE` | `1` SHA256, `2` SHA384, `3` SHA512 | `1` |
| `TLS_SIG_CHOICE` | `1` tls-crypt, `2` tls-auth | `1` |
| `INSTALL_LUCI` | `y` / `n` (install `luci-app-openvpn`) | `y` if LuCI is installed, otherwise `n` |
| `CLIENT_FILES_DIR` | absolute directory for client `.ovpn` files | `/root` |
| `CLIENT_DAYS_DEFAULT` | default client certificate lifetime, days 1-3650 | `3650` |
| `CLIENT_DAYS` | first client's certificate lifetime, days 1-3650 | `CLIENT_DAYS_DEFAULT` |
| `CLIENT` | first client name `[A-Za-z0-9_-]+` | `client` |
| `PASS` | `1` passwordless, `2` password (interactive only) | `1` |

The encryption variables (`CIPHER_CHOICE` through `TLS_SIG_CHOICE`) are used
only with `CUSTOMIZE_ENC=y`. A value that does not pass validation stops the
script with an error. This also applies to interactive runs: any of these
variables that is already set skips its question.

### Managing an existing installation

Set `MENU_OPTION` to answer the menu without a terminal:

```sh
MENU_OPTION=1 CLIENT=phone ./openvpn-install.sh             # add client "phone" (passwordless)
MENU_OPTION=2 CLIENT=phone ./openvpn-install.sh             # revoke client "phone"
MENU_OPTION=3 ./openvpn-install.sh                          # remove OpenVPN (keeps packages)
MENU_OPTION=3 REMOVE_PACKAGES=y ./openvpn-install.sh        # remove OpenVPN and the packages it installed
```

| Variable | Used by | Meaning |
|----------|---------|---------|
| `MENU_OPTION` | all | `1` add, `2` revoke, `3` remove, `4` exit |
| `CLIENT` | 1, 2 | client name (required) |
| `CLIENT_DAYS` | 1 | certificate lifetime in days, 1-3650 (default: the one chosen at install) |
| `PASS` | 1 | `1` passwordless (default); `2` needs a terminal |
| `REMOVE_CONFIRM` | 3 | `y` (default when headless) / `n` |
| `REMOVE_PACKAGES` | 3 | `y` / `n` (default `n`) |

## What it changes on the router

Everything goes through UCI. Every section has a name that belongs to the
script, and removal deletes exactly those sections. Below, `<instance>` is
the instance name from question 1 (default `openvpninstall`) and
`<client dir>` is the directory from question 13 (default `/root`).

| Where | What |
|-------|------|
| `/etc/config/openvpn` | section `<instance>` (type `openvpn`): the server instance. In LuCI form mode it holds the init script's native options (`dev tunN`, `server`, `topology subnet`, `tls_crypt`/`tls_auth`, `crl_verify`, `data_ciphers`, `list push`, `user nobody`, ...); in text file mode only `enabled` and `config '/etc/openvpn/<instance>.ovpn'`. Section `ovpninstall_meta` (type `ovpninstall`): the installer's own state (instance name, config mode, client directory, the client template: protocol, port, auth, cipher, tls-crypt/tls-auth, compression; endpoint, routing mode, interface name, tun device, certificate settings, packages it installed, whether it changed dnsmasq). The init script ignores this section. |
| `/etc/config/network` | interface with the chosen name (default `vpn`): `proto none`, `device tunN` |
| `/etc/config/firewall` | zone `ovpninstall_zone` (name and network = the chosen interface name, input/output ACCEPT, forward REJECT); rule `ovpninstall_rule` (`Allow-OpenVPN-<instance>`: the chosen port/protocol from `wan` to the router); forwardings `ovpninstall_fwd_lan` and/or `ovpninstall_fwd_wan`, depending on the routing mode |
| `/etc/config/dhcp` | only when the router is the clients' DNS server and dnsmasq is limited to an explicit `interface` list: the VPN interface is added to that list. With the stock configuration (`localservice`, no interface list), dnsmasq already answers on the VPN subnet and nothing is changed. |
| `/etc/openvpn/<instance>/` | `pki/` (easy-rsa PKI), `server/` (CA, server certificate and key, TLS key, CRL readable by `nobody`), `easyrsa-vars` |
| `/etc/openvpn/<instance>.ovpn` | text file mode only: the server configuration (mode 600) |
| `<client dir>/<name>.ovpn` | client configuration files |
| `/etc/sysupgrade.conf` | the line `/etc/openvpn/<instance>/` and, in text file mode, also `/etc/openvpn/<instance>.ovpn` |

The OpenVPN service is enabled and reloaded. procd starts or stops only the
`<instance>` instance, so other OpenVPN instances keep running.

## Revoking clients

Revoking a client revokes its certificate, regenerates the CRL, copies it to
the file that `crl_verify` points to, and deletes `<client dir>/<name>.ovpn`.
OpenVPN reads the CRL again on every TLS handshake, so no restart is needed.
A revoked client that is still connected is dropped at its next
renegotiation, which happens at most one hour later.

## Sysupgrade

`/etc/config/*`, `/etc/openvpn/<instance>/` (keys, certificates and the
PKI) and, in text file mode, `/etc/openvpn/<instance>.ovpn` survive a
sysupgrade. The **packages do not**. Client `.ovpn` files survive only if
their directory is preserved by sysupgrade; the default `/root` is not.
After a sysupgrade, reinstall the packages:

```sh
opkg update && opkg install openvpn-openssl openvpn-easy-rsa   # 22.03 - 24.10
apk update && apk add openvpn-openssl openvpn-easy-rsa         # 25.12+
/etc/init.d/openvpn enable && /etc/init.d/openvpn start
```

Existing client files keep working. To get a lost `.ovpn` file back, revoke
that client and add it again.

## Uninstall

Run the script and choose **3) Remove OpenVPN**, or run
`MENU_OPTION=3 ./openvpn-install.sh`. The removal:

- deletes the `<instance>` OpenVPN instance and its state section
  `ovpninstall_meta`, which stops the instance;
- disables the OpenVPN service if it was not enabled before the
  installation;
- deletes the VPN network interface, the firewall zone, rule and
  forwardings, and the dnsmasq change if one was made;
- deletes `/etc/openvpn/<instance>/`, the text configuration file
  `/etc/openvpn/<instance>.ovpn` (text file mode), the client `.ovpn` files
  in `<client dir>` (the directory itself is left in place) and the
  `sysupgrade.conf` lines;
- reloads network, firewall, dnsmasq (if it was changed) and OpenVPN;
- offers to remove the packages the installer added. Packages that were
  present before the installation are never removed.

## Limitations

- IPv4 only. The tunnel carries IPv4. In routing modes 1 and 2, client IPv6
  traffic does not go through the VPN.
- The VPN subnet is always a `/24`.
- Supports the OpenVPN init script used by OpenWrt 22.03 to 25.12. Builds
  that manage OpenVPN only through netifd, without `/etc/init.d/openvpn`,
  are refused.
- Password-protected client keys need an interactive terminal: easy-rsa asks
  for the password.

## License

[MIT](LICENSE)
