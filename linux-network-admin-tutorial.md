# Linux Network Administration: The Complete Beginner-Friendly Tutorial

*A study guide for Linux networking certification (LPIC, RHCSA/RHCE, Linux+, LFCS and similar). Written in plain language, with hands-on labs and a quiz.*

---

## Table of Contents

1. [How to Use This Tutorial](#1-how-to-use-this-tutorial)
2. [Quick Start: Set Up a Server's Network Step by Step](#2-quick-start-set-up-a-servers-network-step-by-step)
3. [Background: How Networking Works on Linux](#3-background-how-networking-works-on-linux)
4. [Network Interface Names](#4-network-interface-names)
5. [The Big Picture: Legacy Tools vs. Modern Tools](#5-the-big-picture-legacy-tools-vs-modern-tools)
6. [Looking at Interfaces and IP Addresses](#6-looking-at-interfaces-and-ip-addresses)
7. [Routing: How Packets Find Their Way](#7-routing-how-packets-find-their-way)
8. [ARP and Neighbors](#8-arp-and-neighbors)
9. [DNS: Turning Names into Numbers](#9-dns-turning-names-into-numbers)
10. [Hostnames](#10-hostnames)
11. [Testing Connections: ping, traceroute, mtr, curl, nc](#11-testing-connections-ping-traceroute-mtr-curl-nc)
12. [Ports and Sockets: ss, netstat, lsof](#12-ports-and-sockets-ss-netstat-lsof)
13. [Watching Packets: tcpdump, tshark, Wireshark, nmap](#13-watching-packets-tcpdump-tshark-wireshark-nmap)
14. [Persistent Configuration: The Network Managers](#14-persistent-configuration-the-network-managers)
15. [Firewalls: nftables, iptables, firewalld, ufw](#15-firewalls-nftables-iptables-firewalld-ufw)
16. [Advanced Interfaces: VLANs, Bridges, Bonds](#16-advanced-interfaces-vlans-bridges-bonds)
17. [IPv6 Essentials](#17-ipv6-essentials)
18. [Logs and Kernel Settings](#18-logs-and-kernel-settings)
19. [Remote Access: SSH Tools](#19-remote-access-ssh-tools)
20. [Distribution Cheat Sheet](#20-distribution-cheat-sheet)
21. [Gotchas: Things That Trip People Up](#21-gotchas-things-that-trip-people-up)
22. [Best Practices](#22-best-practices)
23. [The Troubleshooting Ladder](#23-the-troubleshooting-ladder)
24. [Hands-On Labs](#24-hands-on-labs)
25. [Quiz](#25-quiz)
26. [Quiz Answers](#26-quiz-answers)
27. [One-Page Command Cheat Sheet](#27-one-page-command-cheat-sheet)

---

## 1. How to Use This Tutorial

Think of a Linux server as a house. Networking is the set of roads, mailboxes, phone lines, and door locks that let the house talk to the rest of the world. This tutorial teaches you every important tool for building those roads, finding out why mail isn't arriving, and locking the doors.

**What you need:**

- A Linux machine you are allowed to break. A virtual machine (VirtualBox, VMware, KVM/virt-manager, UTM, or a cloud VM) is perfect.
- Ideally two VMs so they can talk to each other.
- Root access (`sudo`).
- We show examples for four families of Linux:
  - **Red Hat family:** RHEL, Rocky Linux, AlmaLinux, CentOS Stream, Fedora, Oracle Linux
  - **Debian family:** Debian, Ubuntu, Linux Mint, Pop!_OS
  - **SUSE family:** SLES, openSUSE Leap / Tumbleweed
  - **Arch family:** Arch, Manjaro, EndeavourOS

**Legend used in this guide:**

| Symbol | Meaning |
|---|---|
| 🟢 | Modern / recommended tool |
| 🟡 | Still works but being replaced |
| 🔴 | Legacy / deprecated: know it for exams and old servers, but don't build new things with it |
| ⚠️ | Gotcha: something that surprises people |
| ✅ | Best practice |

---

## 2. Quick Start: Set Up a Server's Network Step by Step

Before all the theory, let's do one real thing from start to finish: **give a server a fixed (static) IP address, a gateway, and DNS servers, and prove it works.** This is the number-one task on almost every Linux networking exam.

Our example plan:

| Setting | Value |
|---|---|
| Interface (network card) | `ens192` (yours may be `eth0`, `enp0s3`, `ens3`, etc.) |
| IP address | `192.168.10.50/24` |
| Gateway (the router) | `192.168.10.1` |
| DNS servers | `192.168.10.1` and `1.1.1.1` |
| Hostname | `web01.example.lan` |

### Step 1: Find out what you have

```bash
# What interfaces exist and what addresses do they have right now?
ip -br addr

# Example output:
# lo        UNKNOWN  127.0.0.1/8 ::1/128
# ens192    UP       192.168.10.137/24 fe80::1c2e:...

# Which network manager is in charge on this system?
systemctl is-active NetworkManager systemd-networkd wicked networking
```

Whichever service says `active` is the one that controls your network. This matters! If you edit the wrong config file, your change will vanish at reboot.

### Step 2: Set the static IP (pick the method for your distro)

#### Option A: NetworkManager with `nmcli` 🟢
*(Default on RHEL/Rocky/Alma/Fedora, Ubuntu Desktop, openSUSE, Debian desktop, and many others)*

```bash
# See the connection profiles (a "profile" is a saved set of settings for an interface)
nmcli connection show

# Modify the profile (replace "ens192" with your profile name if it's different)
sudo nmcli connection modify ens192 \
  ipv4.method manual \
  ipv4.addresses 192.168.10.50/24 \
  ipv4.gateway 192.168.10.1 \
  ipv4.dns "192.168.10.1 1.1.1.1" \
  ipv4.dns-search example.lan

# Apply it (bring the connection down and up)
sudo nmcli connection up ens192
```

If there is no profile yet, create one:

```bash
sudo nmcli connection add type ethernet con-name ens192 ifname ens192 \
  ipv4.method manual ipv4.addresses 192.168.10.50/24 \
  ipv4.gateway 192.168.10.1 ipv4.dns "192.168.10.1 1.1.1.1"
```

#### Option B: Netplan 🟢
*(Default on Ubuntu Server 18.04 and newer)*

Create or edit a file in `/etc/netplan/` (for example `/etc/netplan/50-cloud-init.yaml` or a new `01-static.yaml`):

```yaml
network:
  version: 2
  renderer: networkd        # Ubuntu Server uses systemd-networkd underneath
  ethernets:
    ens192:
      dhcp4: false
      addresses:
        - 192.168.10.50/24
      routes:
        - to: default
          via: 192.168.10.1
      nameservers:
        search: [example.lan]
        addresses: [192.168.10.1, 1.1.1.1]
```

Then test and apply:

```bash
sudo netplan try      # applies, then rolls back after 120 s unless you press Enter. Very safe!
sudo netplan apply    # apply for real
```

⚠️ YAML cares about spaces. Use spaces, never tabs. Two spaces per level.
⚠️ Netplan files must have permissions `600` (`sudo chmod 600 /etc/netplan/*.yaml`) or newer versions warn you.

#### Option C: `/etc/network/interfaces` with ifupdown 🟡
*(Default on Debian servers without NetworkManager)*

```
auto ens192
iface ens192 inet static
    address 192.168.10.50/24
    gateway 192.168.10.1
    dns-nameservers 192.168.10.1 1.1.1.1
    dns-search example.lan
```

```bash
sudo ifdown ens192 && sudo ifup ens192
# or
sudo systemctl restart networking
```

(`dns-nameservers` only works if the `resolvconf` package is installed; otherwise edit `/etc/resolv.conf` directly.)

#### Option D: systemd-networkd 🟢
*(Common on Arch, minimal containers, some cloud images)*

Create `/etc/systemd/network/20-wired.network`:

```ini
[Match]
Name=ens192

[Network]
Address=192.168.10.50/24
Gateway=192.168.10.1
DNS=192.168.10.1
DNS=1.1.1.1
Domains=example.lan
```

```bash
sudo systemctl enable --now systemd-networkd systemd-resolved
sudo networkctl reload
sudo networkctl reconfigure ens192
```

### Step 3: Set the hostname

```bash
sudo hostnamectl set-hostname web01.example.lan
hostnamectl            # confirm
```

Also add a line to `/etc/hosts` so the server can always find its own name even if DNS is down:

```
192.168.10.50   web01.example.lan   web01
```

### Step 4: Verify everything

```bash
ip -br addr show ens192        # Is the address there?
ip route                       # Is "default via 192.168.10.1" there?
ping -c 3 192.168.10.1         # Can I reach the router?
ping -c 3 1.1.1.1              # Can I reach the internet by IP?
ping -c 3 example.com          # Does DNS work?
resolvectl status              # (on systemd-resolved systems) which DNS servers am I using?
cat /etc/resolv.conf           # (on other systems)
```

If every step works, congratulations, you just did the core job of a Linux network admin. The rest of this tutorial explains *why* each piece works and what to do when it doesn't.

### Step 5: Understand the "layers" you just touched

```
   You typed:            nmcli / netplan / interfaces file / .network file
          ↓
   Network manager:      NetworkManager / netplan→networkd / ifupdown / systemd-networkd
          ↓
   Kernel (the engine):  ip addresses, routes, interfaces, firewall rules
          ↓
   Network card → cable/Wi-Fi → router → internet
```

The `ip` command talks to the kernel directly. The network managers write config files AND talk to the kernel so the settings **survive a reboot.** That difference (temporary vs. persistent) is the single most important idea in this tutorial.

---

## 3. Background: How Networking Works on Linux

### 3.1 The postal system analogy

- **IP address** = the street address of a house. Example: `192.168.10.50`
- **Subnet mask / prefix** = which houses are on your street (your "local network"). `/24` means the first 24 bits (the first three numbers) are the street name, so `192.168.10.anything` is a neighbor.
- **Gateway / default route** = the post office. If the letter is not for your street, hand it to the post office and let it figure it out.
- **DNS** = the phone book. It turns `google.com` into `142.250.x.x`.
- **MAC address** = the serial number stamped on your network card, like `52:54:00:ab:cd:ef`. Used only on your local street.
- **ARP** = shouting on your street, "Who has 192.168.10.1? Tell me your MAC address!"
- **Port** = an apartment number inside the house. Web servers usually live at apartment 80 (HTTP) or 443 (HTTPS), SSH at 22, DNS at 53.
- **Socket** = an open door on a specific port, ready to talk.
- **Firewall** = the security guard who decides which doors are open to which visitors.

### 3.2 The OSI-ish layers (the simple version)

| Layer | What it is | Tools that live here |
|---|---|---|
| Physical/Link (Layer 1–2) | Cables, Wi-Fi, MAC addresses, switches | `ip link`, `ethtool`, `iw`, `ip neigh`, `arp` |
| Network (Layer 3) | IP addresses, routers, routes | `ip addr`, `ip route`, `ping`, `traceroute` |
| Transport (Layer 4) | TCP and UDP, ports | `ss`, `netstat`, `nc`, firewalls |
| Application (Layer 7) | HTTP, DNS, SSH... | `curl`, `dig`, `ssh`, `wget` |

When troubleshooting, **start at the bottom and work up.** Is the cable plugged in? Do I have an IP? Can I reach the gateway? Can I resolve names? Can I reach the service?

### 3.3 Where settings live

Linux keeps three kinds of state:

1. **Running (live) state in the kernel.** Shown by `ip`, `ss`, `nft list ruleset`. Changed instantly by `ip` commands. **Lost at reboot.**
2. **Persistent config files** managed by a network manager. Survive reboot.
3. **Kernel tunables** in `/proc/sys/net/` (changed with `sysctl`, made persistent in `/etc/sysctl.d/`).

### 3.4 TCP vs UDP in one paragraph

**TCP** is like a phone call: you connect first, every word is confirmed, nothing is lost or out of order. Used for web pages, SSH, email. **UDP** is like mailing postcards: fast, no confirmation, some may be lost. Used for DNS lookups, video streaming, games, NTP time sync.

---

## 4. Network Interface Names

Old Linux called every wired card `eth0`, `eth1`, and every wireless card `wlan0`. Problem: the numbers could swap between boots if the kernel found the cards in a different order. Imagine your firewall rule for "the internet card" suddenly applying to "the internal card"!

Modern systemd uses **Predictable Network Interface Names**, based on where the hardware is plugged in:

| Name pattern | Meaning | Example |
|---|---|---|
| `enoN` | Onboard card number N (from the BIOS) | `eno1` |
| `ensN` | Card in PCI hotplug slot N | `ens192` (very common in VMware) |
| `enpXsY` | Card at PCI bus X, slot Y | `enp0s3` (very common in VirtualBox) |
| `enxMAC` | Named after the MAC address | `enx001122334455` |
| `wlpXsY` | Wireless at PCI bus X, slot Y | `wlp2s0` |
| `lo` | Loopback: the machine talking to itself, always `127.0.0.1` | `lo` |
| `eth0` | Old-style name. Still seen in Docker containers, some cloud images, Raspberry Pi OS, and when predictable naming is turned off | `eth0` |

Other names you will meet: `docker0`, `virbr0`, `br0` (bridges), `bond0`, `team0` (bonded cards), `tun0`, `wg0` (VPNs), `ens192.100` (VLAN 100 on `ens192`), `veth...` (virtual cables to containers).

⚠️ **Gotcha:** If you clone a VM, the new machine may get a new interface name because it has a different virtual "slot," so your old config that says `ens192` silently does nothing. Always check `ip link` on a new machine first.

✅ You can rename interfaces with a systemd `.link` file in `/etc/systemd/network/` or with `nmcli` (`connection.interface-name`) or udev rules. Only do this if you have a good reason.

---

## 5. The Big Picture: Legacy Tools vs. Modern Tools

The most important table in this tutorial. Old exams and old servers use the left column; modern systems use the right column. **Know both.**

| Job | 🔴 Legacy tool (package `net-tools`) | 🟢 Modern tool (package `iproute2`) |
|---|---|---|
| Show/set addresses & interfaces | `ifconfig` | `ip addr`, `ip link` |
| Show/set routes | `route` | `ip route` |
| Show ARP table | `arp` | `ip neigh` |
| Show sockets / ports | `netstat` | `ss` |
| Show interface stats | `netstat -i` | `ip -s link` |
| Tunnels | `iptunnel` | `ip tunnel` |
| Multicast | `ipmaddr` | `ip maddr` |
| Bring interface up/down | `ifconfig eth0 up` | `ip link set eth0 up` |
| Wireless | `iwconfig` (package `wireless-tools`) | `iw`, `nmcli device wifi` |
| Firewall | `iptables`, `ip6tables`, `ebtables`, `arptables` | `nft` (nftables) or a front-end (`firewalld`, `ufw`) |
| DNS lookup | `nslookup` | `dig`, `resolvectl query`, `host` |
| Network config (RHEL) | `ifcfg-*` files, `network` service | NetworkManager keyfiles, `nmcli` |
| Network config (Ubuntu) | `/etc/network/interfaces` | Netplan |
| Network config (SUSE) | `wicked` | NetworkManager (default from SLE 16 / recent openSUSE) |
| Traceroute | `traceroute` | `tracepath`, `mtr` (traceroute still fine) |
| Remote shell | `telnet`, `rsh` | `ssh` |

**Why did they change?**
- `net-tools` (`ifconfig`, `netstat`, `route`) stopped being actively developed years ago. It doesn't understand many modern kernel features (multiple addresses per interface properly, policy routing, namespaces, VRFs).
- `iproute2` uses the kernel's modern **netlink** interface, is faster, and has one consistent syntax: `ip OBJECT COMMAND`.
- `iptables` had four separate tools and slow rule updates. `nftables` is one tool, faster, with sets and maps. Today's `iptables` command on most distros is actually `iptables-nft`, a translator that writes nftables rules underneath.

⚠️ **Gotcha:** On a fresh minimal RHEL 9/10, Fedora, or Debian 12/13 install, `ifconfig` and `netstat` **are not even installed.** You'll get "command not found." Install `net-tools` only if you really need it; better, learn `ip` and `ss`.

⚠️ **Gotcha:** `ifconfig` may show only the *first* IPv4 address on an interface, hiding others. `ip addr` shows them all. This has caused real outages where an admin thought an address was free.

---

## 6. Looking at Interfaces and IP Addresses

### 6.1 The `ip` command 🟢

Syntax: `ip [options] OBJECT COMMAND`. Objects: `link`, `addr` (or `address`), `route`, `neigh`, `rule`, `netns`, `tunnel`, `maddr`, `-s` for stats.

**Helpful options:**

| Option | Meaning |
|---|---|
| `-br` / `-brief` | Short one-line-per-item output. Use this all the time. |
| `-c` / `-color` | Colors |
| `-4` / `-6` | Only IPv4 / only IPv6 |
| `-s` | Statistics (`ip -s link` shows packet counters and errors) |
| `-j` | JSON output (great for scripts; pair with `jq`) |
| `-d` | Details |

**Looking:**

```bash
ip link                         # interfaces, MAC addresses, state (UP/DOWN), MTU
ip -br link                     # short version
ip addr                         # everything including IP addresses
ip -br -c addr                  # short and colorful
ip -4 addr show dev ens192      # only IPv4 on one interface
ip -s link show ens192          # packet counters: look for errors, dropped
ip -j addr | jq '.[].ifname'    # JSON for scripts
```

Reading `ip addr` output:

```
2: ens192: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UP group default qlen 1000
    link/ether 00:0c:29:3e:4f:aa brd ff:ff:ff:ff:ff:ff
    inet 192.168.10.50/24 brd 192.168.10.255 scope global noprefixroute ens192
       valid_lft forever preferred_lft forever
    inet6 fe80::20c:29ff:fe3e:4faa/64 scope link
```

- `UP` = admin turned it on. `LOWER_UP` = cable is actually connected/link detected. **If you see `NO-CARRIER`, the cable is unplugged or the switch port is dead.**
- `mtu 1500` = biggest packet size (Maximum Transmission Unit).
- `link/ether` = MAC address.
- `inet` = IPv4, `inet6` = IPv6. `fe80::` is the automatic "link-local" IPv6 address every interface gets.
- `scope global` = usable on the network; `scope link` = only on this cable; `scope host` = only on this machine (loopback).
- `valid_lft forever` = static. DHCP addresses show a countdown in seconds.

**Changing (temporary, gone at reboot):**

```bash
sudo ip link set ens192 up                  # turn on
sudo ip link set ens192 down                # turn off (careful over SSH!)
sudo ip addr add 192.168.10.51/24 dev ens192   # add a second address
sudo ip addr del 192.168.10.51/24 dev ens192   # remove it
sudo ip addr flush dev ens192               # remove ALL addresses (careful!)
sudo ip link set ens192 mtu 9000            # jumbo frames
sudo ip link set ens192 address 02:11:22:33:44:55   # change MAC (must be down first on some drivers)
sudo ip link set dev ens192 promisc on      # promiscuous mode for sniffing
```

⚠️ **Gotcha: forgetting the `/24`.** `ip addr add 192.168.10.51 dev ens192` without a prefix gives you `/32`, meaning "no neighbors," so nothing on the LAN is reachable directly. Always include the prefix.

### 6.2 `ifconfig` 🔴

```bash
ifconfig                     # show active interfaces
ifconfig -a                  # show all, including down
sudo ifconfig eth0 192.168.10.50 netmask 255.255.255.0 up
sudo ifconfig eth0:1 192.168.10.51     # old-style "alias" for a second address
```

Know it for old servers and old exam questions. Note that it uses dotted netmasks (`255.255.255.0`) instead of prefix length (`/24`). Conversion cheat: `/24 = 255.255.255.0`, `/16 = 255.255.0.0`, `/25 = 255.255.255.128`, `/30 = 255.255.255.252` (2 usable hosts), `/32 = 255.255.255.255` (a single host).

### 6.3 `ethtool`: the physical layer 🟢

`ethtool` talks to the network card driver. Use it when you suspect cables, speed, or duplex problems.

```bash
sudo ethtool ens192            # speed, duplex, link detected: yes/no
sudo ethtool -i ens192         # driver name and version
sudo ethtool -S ens192         # driver statistics (errors, collisions, CRC errors)
sudo ethtool -k ens192         # offload features (TSO, GSO, checksum offload)
sudo ethtool -K ens192 gro off # turn off an offload feature (sometimes fixes weird packet-capture or VM issues)
sudo ethtool -p ens192 10      # blink the port LED for 10 s so you can find the cable in the rack!
sudo ethtool -s ens192 speed 1000 duplex full autoneg on
```

⚠️ **Gotcha: duplex mismatch.** If one side is forced to `100 full` and the other side autonegotiates, the second side falls back to `half duplex`. Result: the link "works" but is horribly slow with tons of errors. Rule: **both sides auto, or both sides forced.** Check with `ethtool` and look at `ethtool -S` for `collisions`/`crc_errors`.

⚠️ In VMs, `ethtool` shows a virtual "speed" that may be fake (e.g. 10000Mb/s on a laptop). Don't panic.

### 6.4 Wireless: `iw`, `iwconfig`, `nmcli device wifi`

Servers rarely use Wi-Fi, but exams and laptops do.

```bash
nmcli device wifi list                       # 🟢 scan
nmcli device wifi connect "MyWifi" password "secret"   # 🟢 join
iw dev                                       # 🟢 show wireless interfaces
iw dev wlp2s0 link                           # 🟢 current connection info
sudo iw dev wlp2s0 scan | grep SSID          # 🟢 raw scan
iwconfig                                     # 🔴 legacy
rfkill list                                  # is Wi-Fi blocked by a hardware/software switch?
```

---

## 7. Routing: How Packets Find Their Way

### 7.1 Reading the routing table

```bash
ip route          # or "ip r"
```

Typical output:

```
default via 192.168.10.1 dev ens192 proto static metric 100
192.168.10.0/24 dev ens192 proto kernel scope link src 192.168.10.50 metric 100
10.20.0.0/16 via 192.168.10.254 dev ens192 proto static
```

Read it like this:
- Line 2: "To reach anything on `192.168.10.0/24`, just put it on the cable (`dev ens192`) directly." The kernel added this automatically when you gave the interface an address (`proto kernel`).
- Line 3: "To reach `10.20.0.0/16`, hand it to the router at `192.168.10.254`."
- Line 1: "For everything else (`default`, also written `0.0.0.0/0`), hand it to `192.168.10.1`."

**Longest prefix wins.** A `/24` route beats a `/16` route, which beats `default`. If two routes tie, the lower `metric` wins.

**Ask the kernel which route it would use:**

```bash
ip route get 8.8.8.8
# 8.8.8.8 via 192.168.10.1 dev ens192 src 192.168.10.50 uid 1000
```

This is one of the best troubleshooting commands there is. It tells you exactly which interface and source address will be used.

### 7.2 Changing routes (temporary)

```bash
sudo ip route add 10.20.0.0/16 via 192.168.10.254
sudo ip route del 10.20.0.0/16
sudo ip route add default via 192.168.10.1
sudo ip route replace default via 192.168.10.2      # change the gateway
sudo ip route add 10.30.0.0/24 dev tun0             # route via an interface (point-to-point links, VPNs)
sudo ip route add blackhole 10.99.0.0/16            # drop packets silently
```

Making it persistent:

```bash
# NetworkManager
sudo nmcli connection modify ens192 +ipv4.routes "10.20.0.0/16 192.168.10.254"
sudo nmcli connection up ens192

# Netplan (under the interface):
#   routes:
#     - to: 10.20.0.0/16
#       via: 192.168.10.254

# systemd-networkd (in the .network file):
#   [Route]
#   Destination=10.20.0.0/16
#   Gateway=192.168.10.254

# ifupdown (/etc/network/interfaces, under the iface):
#   up ip route add 10.20.0.0/16 via 192.168.10.254
```

### 7.3 Legacy `route` and `netstat -r` 🔴

```bash
route -n                # -n = numbers, don't look up names
netstat -rn             # same thing
sudo route add -net 10.20.0.0/16 gw 192.168.10.254
sudo route add default gw 192.168.10.1
```

### 7.4 Turning a Linux box into a router

By default Linux does **not** forward packets between interfaces. To make it a router:

```bash
sysctl net.ipv4.ip_forward                # check (0 = off)
sudo sysctl -w net.ipv4.ip_forward=1      # temporary
echo "net.ipv4.ip_forward = 1" | sudo tee /etc/sysctl.d/99-forward.conf   # persistent
sudo sysctl --system                      # reload
```

For NAT (sharing one public IP, like a home router), add a masquerade rule in the firewall (see Section 15).

### 7.5 Policy routing: `ip rule` (advanced)

Linux can have **multiple routing tables** and choose one based on the source address, mark, or interface. Used for "traffic from this IP goes out via ISP B."

```bash
ip rule                                     # list rules (default: local, main, default tables)
echo "100 isp2" | sudo tee -a /etc/iproute2/rt_tables       # name a table
sudo ip route add default via 203.0.113.1 table isp2
sudo ip rule add from 203.0.113.50 table isp2
ip route show table isp2
```

⚠️ Two interfaces, two gateways, one routing table = a classic broken setup. Reply packets go out the wrong interface and get dropped by strict ISPs. Policy routing fixes it.

---

## 8. ARP and Neighbors

ARP (Address Resolution Protocol) maps IP → MAC on the local network. IPv6 uses NDP (Neighbor Discovery) for the same job. Linux stores both in the **neighbor table**.

```bash
ip neigh                       # 🟢 show table (or "ip n")
ip -4 neigh show dev ens192
sudo ip neigh flush dev ens192 # clear it
sudo ip neigh add 192.168.10.7 lladdr 00:11:22:33:44:55 dev ens192 nud permanent   # static entry
arp -n                         # 🔴 legacy
arping -I ens192 192.168.10.1  # send ARP request directly; great for "is anything using this IP?"
```

States you'll see: `REACHABLE` (good), `STALE` (old but probably fine), `DELAY`/`PROBE` (checking), `FAILED` (nobody answered: the host is off, or you're on the wrong VLAN, or there's an IP typo), `PERMANENT` (static).

⚠️ **Gotcha: duplicate IP addresses.** Two machines with the same IP fight over ARP. Symptoms: connections work, then drop, then work. Find it with `arping -D -I ens192 192.168.10.50` (duplicate address detection) or by watching `ip neigh` flip between two MACs.

---

## 9. DNS: Turning Names into Numbers

### 9.1 How a name gets looked up

When a program asks for `example.com`, the C library (glibc) follows `/etc/nsswitch.conf`:

```
hosts: files myhostname resolve [!UNAVAIL=return] dns
```

Meaning: check `/etc/hosts` (`files`) → the machine's own hostname (`myhostname`) → systemd-resolved (`resolve`) → regular DNS (`dns`). Order matters.

### 9.2 The files

| File | Purpose |
|---|---|
| `/etc/hosts` | Manual name→IP list. Checked first. Great for testing a site before DNS changes. |
| `/etc/resolv.conf` | Which DNS servers to ask (`nameserver`), default `search` domains, `options` |
| `/etc/nsswitch.conf` | The order of lookup sources |
| `/etc/hostname` | The machine's name |

Example `/etc/resolv.conf`:

```
search example.lan corp.example.com
nameserver 192.168.10.1
nameserver 1.1.1.1
options timeout:2 attempts:2
```

`search` means if you type `ping web01`, it tries `web01.example.lan`, then `web01.corp.example.com`.

⚠️ **Gotcha #1 (the biggest DNS gotcha on Linux): `/etc/resolv.conf` keeps getting overwritten!** On most modern systems this file is *generated* by NetworkManager, systemd-resolved, resolvconf, or DHCP. If you edit it by hand, your edit disappears on the next reboot or DHCP renewal. Fix it at the source:

| Who owns resolv.conf? | How to tell | How to set DNS properly |
|---|---|---|
| systemd-resolved | `ls -l /etc/resolv.conf` shows a symlink to `/run/systemd/resolve/stub-resolv.conf`; file contains `nameserver 127.0.0.53` | `resolvectl dns ens192 1.1.1.1`, or via netplan/networkd/NetworkManager, or `/etc/systemd/resolved.conf` |
| NetworkManager | Comment `# Generated by NetworkManager` | `nmcli connection modify ens192 ipv4.dns "1.1.1.1"` |
| resolvconf (Debian) | Comment mentions resolvconf | `/etc/resolvconf/resolv.conf.d/head` or `dns-nameservers` in `/etc/network/interfaces` |
| dhclient | Plain file, changes after DHCP renew | `/etc/dhcp/dhclient.conf` with `supersede domain-name-servers 1.1.1.1;` |
| Nobody (static) | Plain file, no generator comment | Just edit it |

To make NetworkManager stop touching it: in `/etc/NetworkManager/NetworkManager.conf` add `[main] dns=none` and `rc-manager=unmanaged`, then restart NetworkManager.

⚠️ **Gotcha #2:** `nameserver 127.0.0.53` is **not** a mistake. That is systemd-resolved's local "stub" listener. The real upstream servers are shown by `resolvectl status`.

### 9.3 systemd-resolved and `resolvectl` 🟢

Default on Ubuntu 18.04+, Fedora 33+, and many others. It caches answers, supports per-interface DNS (VPN gets its own DNS servers), DNS-over-TLS, and mDNS/LLMNR.

```bash
resolvectl status                     # per-interface DNS servers, search domains, DNSSEC
resolvectl query example.com          # look up a name using the system config
resolvectl statistics                 # cache hits
sudo resolvectl flush-caches          # clear the cache
sudo resolvectl dns ens192 1.1.1.1 9.9.9.9      # set servers for an interface (temporary)
sudo resolvectl domain ens192 example.lan
systemd-resolve --status              # 🟡 older name for resolvectl
```

Persistent global settings: `/etc/systemd/resolved.conf` (`DNS=`, `FallbackDNS=`, `DNSOverTLS=yes`, `DNSSEC=`).

### 9.4 Lookup tools: `dig`, `host`, `nslookup`, `getent`

`dig` (package `bind-utils` on RHEL, `dnsutils`/`bind9-dnsutils` on Debian/Ubuntu, `bind` on Arch) is the professional's tool. 🟢

```bash
dig example.com                    # A record, full output
dig example.com +short             # just the answer
dig example.com MX                 # mail servers
dig example.com AAAA               # IPv6 address
dig example.com NS                 # name servers
dig -x 93.184.216.34               # reverse lookup (IP → name, PTR record)
dig @1.1.1.1 example.com           # ask a specific server (skip the local config)
dig example.com +trace             # walk from root servers down: shows exactly where a lookup breaks
dig example.com +dnssec            # check DNSSEC signatures
dig example.com ANY                # (many servers now refuse ANY; mostly historical)
```

Read the important parts of `dig` output:
- `status: NOERROR` = good. `NXDOMAIN` = the name does not exist. `SERVFAIL` = the server had a problem (often DNSSEC or a broken zone). `REFUSED` = the server won't answer you.
- `ANSWER SECTION` = the result. The number after the name is the **TTL** (seconds it may be cached).
- `;; SERVER: 127.0.0.53#53` = which server actually answered.
- `flags: ... aa` = authoritative answer (from the real owner, not a cache).

```bash
host example.com                   # 🟢 simple lookup
host -t MX example.com
nslookup example.com               # 🟡 works everywhere, including Windows; interactive mode is handy
getent hosts example.com           # 🟢 IMPORTANT: uses the same path as real programs (hosts file + nsswitch + DNS)
getent ahosts example.com          # all addresses
```

⚠️ **Gotcha #3:** `dig` and `nslookup` **skip `/etc/hosts` and nsswitch.** They go straight to DNS. So "`dig` works but my app can't resolve" (or the opposite) happens all the time. Use `getent hosts NAME` to test what applications actually see.

⚠️ **Gotcha #4:** DNS uses UDP port 53 for most queries but **TCP port 53** for big answers and zone transfers. A firewall that blocks TCP/53 causes weird partial failures.

⚠️ **Gotcha #5:** Split-horizon/VPN DNS. When a VPN is up you may need company names resolved by the VPN's DNS and everything else by your normal DNS. systemd-resolved does this per interface (`resolvectl domain tun0 ~corp.example.com`). Plain resolv.conf cannot.

### 9.5 Local caching and other resolvers

- `systemd-resolved`: the default cache on most systemd distros.
- `dnsmasq`: light DNS cache + DHCP server. Used by libvirt (`virbr0`) and NetworkManager (`dns=dnsmasq`).
- `unbound`: validating recursive resolver, great for servers.
- `bind9`/`named`: the full authoritative DNS server. Zone files in `/etc/bind/` (Debian) or `/var/named/` (RHEL). `named-checkconf` and `named-checkzone` validate configs. `rndc reload` reloads.
- `nscd` 🔴: old name cache daemon; if it's running and you get stale answers, `nscd -i hosts`.

---

## 10. Hostnames

Three kinds of hostname exist on systemd systems:

| Kind | Meaning |
|---|---|
| **static** | The one in `/etc/hostname`. The "real" name. |
| **transient** | Set by DHCP or the network at runtime. |
| **pretty** | Human-friendly, may contain spaces ("Bob's Laptop"). |

```bash
hostnamectl                                    # show all
sudo hostnamectl set-hostname web01.example.lan  # sets static (and transient)
sudo hostnamectl set-hostname "Web Server 1" --pretty
hostname                                       # 🟡 show current (transient) name
hostname -f                                    # fully qualified name; fails if /etc/hosts or DNS can't resolve it
hostname -I                                    # all IP addresses (capital i)
cat /etc/hostname
```

⚠️ `hostname newname` changes the name only until reboot. Use `hostnamectl` for persistence.

⚠️ `sudo` becoming slow, or "unable to resolve host web01" warnings = your hostname isn't in `/etc/hosts`. Add `127.0.1.1 web01.example.lan web01` (Debian style) or `192.168.10.50 web01.example.lan web01`.

⚠️ On cloud VMs (AWS, Azure, GCP), `cloud-init` may reset the hostname at every boot. Set `preserve_hostname: true` in `/etc/cloud/cloud.cfg` if you change it.

---

## 11. Testing Connections: ping, traceroute, mtr, curl, nc

### 11.1 `ping` 🟢

Sends ICMP "echo request"; the target replies "echo reply." Tells you reachability and round-trip time.

```bash
ping -c 4 192.168.10.1          # 4 packets then stop (without -c it runs forever; Ctrl-C to stop)
ping -c 4 -i 0.2 host           # faster interval (root needed below 0.2 s)
ping -c 4 -s 1472 -M do host    # send a 1500-byte packet with "don't fragment": tests MTU
ping -c 4 -I ens192 host        # use a specific interface / source
ping -4 host / ping -6 host     # force IPv4 / IPv6
ping6 host                      # 🟡 older IPv6 ping
ping -c 4 -W 1 host             # wait max 1 s per reply
ping -f host                    # flood (root): stress test, careful
```

Reading results: `64 bytes from ...: icmp_seq=1 ttl=64 time=0.42 ms` is good. `Destination Host Unreachable` = no route or ARP failed (usually local problem). `Request timeout` / 100% packet loss = something in the path is dropping it or the target is filtering ICMP.

⚠️ **Gotcha:** Many servers and cloud firewalls **block ICMP**, so "ping fails" does not always mean "host is down." Test the actual port with `nc` or `curl` too.

⚠️ **Gotcha: MTU / fragmentation.** If small pings work but big transfers hang (SSH connects then freezes, web pages half-load), suspect an MTU problem on a VPN or tunnel. Test: `ping -M do -s 1472 host` (1472 + 28 header = 1500). If it says "message too long," lower the number until it works, and set that MTU on the tunnel interface (or enable MSS clamping in the firewall).

### 11.2 `traceroute`, `tracepath`, `mtr`

They show each router ("hop") between you and the target.

```bash
traceroute 8.8.8.8              # UDP probes by default (Linux)
traceroute -I 8.8.8.8           # ICMP probes (more like Windows tracert; often gets through firewalls better)
traceroute -T -p 443 host       # TCP probes to port 443 (best when firewalls block everything else)
traceroute -n host              # no DNS lookups (faster)
tracepath host                  # 🟢 no root needed, also discovers path MTU
mtr host                        # 🟢 live, continuous traceroute + ping. The best tool for "the network is flaky."
mtr -rwc 100 host               # report mode: 100 rounds, then print a table (great for tickets to your ISP)
mtr --tcp -P 443 host
```

Reading `mtr`: look at `Loss%` and `Avg` per hop. **A hop showing loss but later hops showing none is fine** (that router just deprioritizes replies to you). Loss that **starts at one hop and continues to the end** is a real problem at that hop.

⚠️ `* * *` in traceroute means that router doesn't send "time exceeded" messages. Not necessarily a problem.

### 11.3 `nc` (netcat): the Swiss army knife 🟢

Two main flavors: OpenBSD netcat (`nc` on Debian/Ubuntu) and `nmap-ncat` (`nc`/`ncat` on RHEL family). Options differ slightly.

```bash
nc -zv host 22                   # "Is port 22 open?" -z = don't send data, -v = verbose
nc -zv host 20-25                # scan a port range
nc -zvu host 53                  # UDP check (unreliable: UDP doesn't answer unless the service replies)
nc -l 9000                       # LISTEN on port 9000 (make a fake server to test firewalls)
echo hello | nc host 9000        # send text to it from another machine
nc host 80                       # then type: GET / HTTP/1.0 and press Enter twice: manual HTTP!
nc -l 9000 > received.bin        # receive a file
nc host 9000 < file.bin          # send a file
```

**The classic firewall test:** on server A run `nc -l 9000`; on server B run `nc -zv A 9000`. If it fails but `ping` works, a firewall between them is blocking that port.

### 11.4 `telnet` 🔴

```bash
telnet host 25        # still a common quick "is the port open, and what banner does it send?" test
```

Use `nc` instead; `telnet` is often not installed and sends everything unencrypted.

### 11.5 `curl` and `wget` 🟢

```bash
curl -I https://example.com               # headers only (HEAD request)
curl -v https://example.com               # verbose: shows DNS, TCP connect, TLS handshake, headers. Superb for debugging.
curl -o file.zip https://.../file.zip     # download
curl -L url                               # follow redirects
curl -k https://self-signed.local         # ignore certificate errors (testing only!)
curl --resolve example.com:443:192.168.10.50 https://example.com   # test a site on a new server before DNS is changed
curl -x http://proxy:3128 url             # via proxy
curl -w "%{http_code} %{time_total}\n" -o /dev/null -s url          # status code and timing
curl ifconfig.me                          # what's my public IP?
curl -4 / curl -6                         # force IP version
wget url                                  # download; -c to resume; -r to mirror
wget -qO- url                             # print to screen
```

⚠️ Proxy environment variables (`http_proxy`, `https_proxy`, `no_proxy`) affect `curl`, `wget`, `apt`, `dnf`, `pip`, and many programs, but **not** `ping` or `ssh`. "curl fails but ping works" on a corporate network often means a proxy variable problem.

### 11.6 Bandwidth: `iperf3`

```bash
iperf3 -s                       # on the server
iperf3 -c server_ip             # on the client: TCP throughput test
iperf3 -c server_ip -u -b 100M  # UDP at 100 Mbit/s, shows loss and jitter
iperf3 -c server_ip -R          # reverse direction
iperf3 -c server_ip -P 4        # 4 parallel streams
```

Also: `nload`, `iftop`, `bmon`, `vnstat` for watching live traffic per interface; `speedtest-cli` for internet speed.

---

## 12. Ports and Sockets: ss, netstat, lsof

A **listening** socket is a service waiting for connections (a door that is open). An **established** socket is a live conversation.

### 12.1 `ss` 🟢 (socket statistics)

Options combine nicely; memorize `ss -tulnp`.

| Option | Meaning |
|---|---|
| `-t` | TCP |
| `-u` | UDP |
| `-l` | listening only |
| `-n` | numbers, don't resolve names (much faster) |
| `-p` | show the process (needs root to see other users' processes) |
| `-a` | all (listening + established) |
| `-s` | summary statistics |
| `-4` / `-6` | IPv4 / IPv6 |
| `-x` | Unix sockets |
| `-o` | timer info |
| `-i` | internal TCP info (RTT, cwnd) |

```bash
ss -tulnp                            # "What is listening, and which program?" THE most-used form
ss -tnp                              # established TCP connections with process
ss -tan state established            # filter by state
ss -tan 'sport = :22'                # who is connected to my SSH?
ss -tan '( dport = :443 or sport = :443 )'
ss -s                                # totals
ss -tlnp | grep :80                  # is the web server up?
ss -K dst 203.0.113.9                # kill sockets to a host (needs kernel support)
```

Reading `ss -tulnp`:

```
Netid State  Recv-Q Send-Q Local Address:Port  Peer Address:Port Process
tcp   LISTEN 0      128    0.0.0.0:22          0.0.0.0:*         users:(("sshd",pid=812,fd=3))
tcp   LISTEN 0      511    127.0.0.1:3306      0.0.0.0:*         users:(("mysqld",pid=1044,fd=20))
tcp   LISTEN 0      511    *:80                *:*               users:(("nginx",pid=900,fd=6))
```

- `0.0.0.0:22` = listening on **all** IPv4 addresses.
- `127.0.0.1:3306` = only local machine can connect. **If a remote client can't reach MySQL, this is why.**
- `*:80` or `[::]:80` = all IPv6 addresses (and usually IPv4 too, unless `bindv6only` is set).
- `Recv-Q` on a LISTEN socket = connections waiting to be accepted; `Send-Q` = the backlog limit. High Recv-Q means the app is too slow to accept connections.

### 12.2 `netstat` 🔴

```bash
netstat -tulnp        # same idea as ss -tulnp
netstat -an
netstat -rn           # routes
netstat -i            # interface stats
netstat -s            # protocol stats
```

Same letters, so the muscle memory transfers. `ss` is faster, especially with thousands of connections.

### 12.3 `lsof` (list open files) 🟢

Because "everything is a file," sockets are files too.

```bash
sudo lsof -i                    # all network files
sudo lsof -i :80                # who is using port 80?
sudo lsof -i TCP -s TCP:LISTEN  # listening TCP
sudo lsof -i @192.168.10.7      # connections to/from that host
sudo lsof -p 1234 -i            # network files of one process
sudo lsof -u www-data -i
```

Also `fuser -n tcp 80` (shows PID using the port) and `fuser -k -n tcp 8080` (kills it).

### 12.4 Port numbers to memorize

| Port | Service | | Port | Service |
|---|---|---|---|---|
| 20/21 | FTP | | 143 / 993 | IMAP / IMAPS |
| 22 | SSH, SFTP, SCP | | 161/162 | SNMP |
| 23 | Telnet | | 389 / 636 | LDAP / LDAPS |
| 25 | SMTP | | 443 | HTTPS |
| 53 | DNS (UDP+TCP) | | 445 | SMB/CIFS |
| 67/68 | DHCP server/client (UDP) | | 465 / 587 | SMTPS / Submission |
| 69 | TFTP (UDP) | | 514 | Syslog |
| 80 | HTTP | | 636 | LDAPS |
| 88 | Kerberos | | 873 | rsync |
| 110 / 995 | POP3 / POP3S | | 2049 | NFS |
| 123 | NTP (UDP) | | 3306 | MySQL/MariaDB |
| | | | 5432 | PostgreSQL |
| | | | 6379 | Redis |
| | | | 3389 | RDP |

Ports below 1024 are "privileged": only root (or a process with `CAP_NET_BIND_SERVICE`) can listen on them. `/etc/services` lists names ↔ numbers.

---

## 13. Watching Packets: tcpdump, tshark, Wireshark, nmap

### 13.1 `tcpdump` 🟢

Captures raw packets. Needs root. Learn the filter language (BPF); it's the same in Wireshark capture filters.

```bash
sudo tcpdump -i ens192                              # everything on that interface (noisy!)
sudo tcpdump -i any                                 # all interfaces
sudo tcpdump -ni ens192 port 53                     # DNS only; -n = don't resolve names (always use -n)
sudo tcpdump -ni ens192 host 192.168.10.7           # to/from one host
sudo tcpdump -ni ens192 src 192.168.10.7 and dst port 443
sudo tcpdump -ni ens192 icmp                        # pings
sudo tcpdump -ni ens192 arp                         # ARP: "who has ...?"
sudo tcpdump -ni ens192 'tcp[tcpflags] & tcp-syn != 0'   # connection attempts (SYN packets)
sudo tcpdump -ni ens192 not port 22                 # hide your own SSH session
sudo tcpdump -ni ens192 -c 100 -w capture.pcap      # save 100 packets to a file for Wireshark
sudo tcpdump -nr capture.pcap                       # read the file
sudo tcpdump -ni ens192 -A port 80                  # show packet contents as text (see HTTP requests)
sudo tcpdump -ni ens192 -X port 80                  # hex + ASCII
sudo tcpdump -ni ens192 -s 0 -vvv port 67 or port 68    # DHCP conversation, full packets, very verbose
sudo tcpdump -ni ens192 -e vlan                     # show VLAN tags and MAC addresses
```

Reading a TCP line:

```
12:00:01.123456 IP 192.168.10.50.51234 > 93.184.216.34.443: Flags [S], seq 12345, win 64240, length 0
```

- `Flags [S]` = SYN (start). `[S.]` = SYN-ACK (server agrees). `[.]` = ACK. `[P.]` = data. `[F.]` = FIN (closing). `[R]` = RST (reset: "go away," usually meaning the port is closed or a firewall rejected it).
- The **three-way handshake** is `[S]` → `[S.]` → `[.]`. If you see `[S]` repeated with no `[S.]`, the packets are being dropped somewhere.

**Combining filters:** `and`, `or`, `not`, parentheses (quote them: `'(port 80 or port 443) and host 1.2.3.4'`).

✅ Capture on **both** ends when possible. If packets leave A but never arrive at B, the problem is in between.

### 13.2 Wireshark and `tshark`

Wireshark is the graphical packet analyzer; `tshark` is its command-line twin. Both read `.pcap` files from `tcpdump`.

```bash
tshark -i ens192 -f "port 53"                       # capture filter (BPF, same as tcpdump)
tshark -r capture.pcap -Y "http.request"           # display filter (Wireshark syntax)
tshark -r capture.pcap -Y "dns" -T fields -e dns.qry.name
tshark -r capture.pcap -q -z conv,tcp               # conversation statistics
```

✅ Add your user to the `wireshark` group (`sudo usermod -aG wireshark $USER`) to capture without full root.

Useful Wireshark display filters: `ip.addr==192.168.10.7`, `tcp.port==443`, `dns`, `http`, `tcp.flags.reset==1`, `tcp.analysis.retransmission`, `icmp`. Right-click → "Follow TCP Stream" is magic.

### 13.3 `nmap`: port scanner 🟢

```bash
nmap 192.168.10.50                   # scan the 1000 most common TCP ports
nmap -p 22,80,443 host               # specific ports
nmap -p- host                        # all 65535 ports (slow)
nmap -sU -p 53,123 host              # UDP scan (slow, needs root)
nmap -sn 192.168.10.0/24             # "ping sweep": which hosts are alive?
nmap -sV host                        # detect service versions
nmap -O host                         # guess the OS (root)
nmap -A host                         # everything: versions, OS, scripts, traceroute
nmap --script vuln host              # vulnerability scripts
```

Results: `open` (service listening), `closed` (reachable but nothing listening: got an RST), `filtered` (firewall dropped the probe: no answer at all).

⚠️ **Only scan machines you own or have written permission to scan.** Scanning other people's systems can be illegal.

---

## 14. Persistent Configuration: The Network Managers

Here's the family tree. Every distro picks a default; you can switch, but **run only one manager per interface.**

| Manager | Default on | Config location | CLI |
|---|---|---|---|
| **NetworkManager** 🟢 | RHEL 7+, Rocky, Alma, Fedora, Ubuntu Desktop, openSUSE (desktop), Debian desktop, SLE 16 | `/etc/NetworkManager/system-connections/*.nmconnection` (keyfiles) | `nmcli`, `nmtui` |
| **Netplan** 🟢 | Ubuntu Server/Cloud 18.04+ | `/etc/netplan/*.yaml` | `netplan` |
| **systemd-networkd** 🟢 | Arch (common), CoreOS/Flatcar, many containers, under Ubuntu Server via netplan | `/etc/systemd/network/*.network`, `*.netdev`, `*.link` | `networkctl` |
| **ifupdown** 🟡 | Debian (server/minimal) | `/etc/network/interfaces`, `/etc/network/interfaces.d/` | `ifup`, `ifdown` |
| **ifcfg / network-scripts** 🔴 | RHEL ≤7 (deprecated in 8, legacy plugin in 9, removed in 10) | `/etc/sysconfig/network-scripts/ifcfg-*` | `ifup`, `ifdown`, `service network restart` |
| **wicked** 🟡 | SLES 12/15, openSUSE Leap (server), being replaced by NetworkManager in SLE 16 | `/etc/sysconfig/network/ifcfg-*` | `wicked`, YaST |
| **netctl** 🔴 | Old Arch | `/etc/netctl/` | `netctl` |
| **cloud-init** | Cloud images | `/etc/cloud/`, writes the distro's native config | |

Find out which one is running:

```bash
systemctl status NetworkManager systemd-networkd networking wicked 2>/dev/null | grep -E "●|Active"
nmcli device                     # if NetworkManager: "unmanaged" means someone else owns that interface
networkctl                       # if networkd
```

### 14.1 NetworkManager: `nmcli` and `nmtui` 🟢

**Concepts:** a **device** is a physical/virtual interface. A **connection** (profile) is a saved set of settings that can be applied to a device. One device can have several profiles (e.g. "Office" and "Home"), but only one active at a time.

```bash
nmcli general status
nmcli device                            # devices and state (connected / disconnected / unmanaged)
nmcli device show ens192                # everything about a device (live values)
nmcli connection show                   # profiles; green = active
nmcli connection show ens192            # all settings of a profile
nmcli -f ipv4 connection show ens192    # just the ipv4 section
nmcli connection up ens192 / down ens192
nmcli connection reload                 # re-read files edited by hand
nmcli device reapply ens192             # apply profile changes without a full down/up
nmcli connection delete "Wired connection 1"
nmcli device set ens192 managed no      # tell NM to leave this interface alone
nmcli networking off / on               # kill switch
nmcli radio wifi off
nmcli monitor                           # watch events
```

**Common settings** (use with `nmcli connection modify NAME setting value`):

| Setting | Values / Example |
|---|---|
| `ipv4.method` | `auto` (DHCP), `manual`, `disabled`, `shared`, `link-local` |
| `ipv4.addresses` | `192.168.10.50/24` (comma list for several) |
| `ipv4.gateway` | `192.168.10.1` |
| `ipv4.dns` | `"1.1.1.1 9.9.9.9"` |
| `ipv4.dns-search` | `example.lan` |
| `ipv4.ignore-auto-dns` | `yes` (keep DHCP's IP but use your own DNS) |
| `ipv4.never-default` | `yes` (don't take a default route from this connection: for second NICs and VPNs) |
| `ipv4.routes` | `"10.20.0.0/16 192.168.10.254"`; use `+ipv4.routes` to add without replacing |
| `ipv4.route-metric` | `50` |
| `ipv6.method` | `auto`, `manual`, `disabled`, `link-local`, `dhcp` |
| `connection.autoconnect` | `yes`/`no` |
| `connection.interface-name` | bind profile to a device |
| `802-3-ethernet.mtu` | `9000` |
| `802-3-ethernet.cloned-mac-address` | `random`, `stable`, or a MAC |
| `connection.zone` | firewalld zone, e.g. `public` |

Setting DHCP:

```bash
sudo nmcli connection modify ens192 ipv4.method auto ipv4.addresses "" ipv4.gateway "" ipv4.dns ""
sudo nmcli connection up ens192
```

Adding a second IP:

```bash
sudo nmcli connection modify ens192 +ipv4.addresses 192.168.10.51/24
sudo nmcli device reapply ens192
```

**`nmtui`** is a text menu (arrow keys). Perfect when you don't remember syntax. "Edit a connection" → pick interface → set IPv4 to Manual → fill in → OK → back → "Activate a connection" → deactivate/activate.

**Keyfile example** (`/etc/NetworkManager/system-connections/ens192.nmconnection`, must be `chmod 600`, owner root):

```ini
[connection]
id=ens192
type=ethernet
interface-name=ens192

[ipv4]
method=manual
address1=192.168.10.50/24,192.168.10.1
dns=192.168.10.1;1.1.1.1;
dns-search=example.lan;

[ipv6]
method=auto
```

After hand-editing: `sudo nmcli connection reload && sudo nmcli connection up ens192`.

⚠️ **RHEL 9/10 gotcha:** the old `ifcfg-*` files in `/etc/sysconfig/network-scripts/` are **deprecated in RHEL 9** (still read via a plugin) and **gone in RHEL 10.** Migrate with `nmcli connection migrate`. Exam answers for RHCSA 9+ expect `nmcli`/`nmtui`.

⚠️ Profiles named "Wired connection 1" are auto-created. Rename them to match the interface to keep your sanity: `nmcli connection modify "Wired connection 1" connection.id ens192`.

⚠️ NetworkManager's `dns=` setting: if you see DNS from a VPN leaking or the wrong DNS used, look at `/etc/NetworkManager/NetworkManager.conf` and `/etc/NetworkManager/conf.d/`.

✅ Dispatcher scripts in `/etc/NetworkManager/dispatcher.d/` run when interfaces go up/down: great for custom routes or restarting services.

### 14.2 Netplan 🟢 (Ubuntu)

Netplan is a **translator**. You write YAML; it generates config for a "renderer": `networkd` (Ubuntu Server default) or `NetworkManager` (Ubuntu Desktop default).

```bash
sudo netplan generate    # just build the backend config, check syntax
sudo netplan try         # apply with automatic rollback: use this over SSH!
sudo netplan apply       # apply
sudo netplan status      # (netplan 0.106+) show current state
sudo netplan get         # dump merged config
netplan --debug apply    # see what it's doing
```

Files in `/etc/netplan/` are merged in alphabetical order; later files override earlier ones. Cloud images ship `50-cloud-init.yaml`; to override without cloud-init rewriting it, create `/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg` containing `network: {config: disabled}` and write your own `01-netcfg.yaml`.

Full-featured example:

```yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    ens192:
      dhcp4: true
      dhcp4-overrides:
        use-dns: false          # take IP from DHCP but not DNS
      nameservers:
        addresses: [1.1.1.1]
    ens224:
      addresses: [10.20.0.5/24]
      routes:
        - to: 10.30.0.0/16
          via: 10.20.0.1
          metric: 100
      mtu: 9000
      optional: true            # don't wait for it at boot
  vlans:
    ens192.100:
      id: 100
      link: ens192
      addresses: [192.168.100.5/24]
  bonds:
    bond0:
      interfaces: [ens256, ens257]
      parameters:
        mode: 802.3ad
        lacp-rate: fast
        mii-monitor-interval: 100
  bridges:
    br0:
      interfaces: [bond0]
      addresses: [192.168.20.5/24]
      routes:
        - to: default
          via: 192.168.20.1
```

⚠️ `gateway4:` is **deprecated**; use `routes: - to: default`. Netplan 1.0 (Ubuntu 24.04) warns; newer versions may refuse.
⚠️ `netplan apply` may **not remove** old addresses/routes on networkd; reboot or use `ip addr flush` when you switch from DHCP to static.
⚠️ Setting `optional: true` avoids a 2-minute boot wait ("Job systemd-networkd-wait-online") on interfaces that aren't always connected.

### 14.3 systemd-networkd 🟢

Three file types in `/etc/systemd/network/` (or `/run/`, `/usr/lib/`), processed in alphabetical order:

- `*.link` : hardware-level settings (rename, MAC, MTU, WoL). Applied by udev.
- `*.netdev` : create virtual devices (bridges, bonds, VLANs, VXLAN, WireGuard, dummy).
- `*.network` : addresses, routes, DNS for matching interfaces.

```bash
networkctl                       # list links and state (routable / degraded / carrier / off)
networkctl status ens192         # details
networkctl status                # global: DNS, routes
sudo networkctl reload           # re-read files
sudo networkctl reconfigure ens192
sudo networkctl up/down ens192
journalctl -u systemd-networkd
```

DHCP `.network`:

```ini
[Match]
Name=en*

[Network]
DHCP=yes
IPv6AcceptRA=yes

[DHCPv4]
UseDNS=false
RouteMetric=100
```

Bridge example: `br0.netdev`:

```ini
[NetDev]
Name=br0
Kind=bridge
```

`ens192.network` (put it in the bridge):

```ini
[Match]
Name=ens192
[Network]
Bridge=br0
```

`br0.network`:

```ini
[Match]
Name=br0
[Network]
Address=192.168.10.50/24
Gateway=192.168.10.1
DNS=1.1.1.1
```

⚠️ networkd needs `systemd-resolved` (or your own resolv.conf handling) for DNS to take effect: `sudo systemctl enable --now systemd-resolved` and `ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf`.
⚠️ File names must end in `.network`, and `[Match]` must match, or nothing happens silently. Check with `networkctl status ens192` (it shows "Network File:").

### 14.4 ifupdown (`/etc/network/interfaces`) 🟡 Debian

```
# Loopback
auto lo
iface lo inet loopback

# DHCP
auto ens192
iface ens192 inet dhcp

# Static, with extra commands
auto ens224
iface ens224 inet static
    address 10.20.0.5/24
    gateway 10.20.0.1
    dns-nameservers 1.1.1.1
    up ip route add 10.30.0.0/16 via 10.20.0.1
    down ip route del 10.30.0.0/16 via 10.20.0.1
    mtu 9000

# IPv6
iface ens224 inet6 static
    address 2001:db8::5/64
    gateway 2001:db8::1

# VLAN (package vlan) and bridge (package bridge-utils)
auto ens192.100
iface ens192.100 inet static
    address 192.168.100.5/24
    vlan-raw-device ens192

auto br0
iface br0 inet static
    address 192.168.20.5/24
    bridge_ports ens256
    bridge_stp off
```

- `auto` = bring up at boot. `allow-hotplug` = bring up when the kernel detects it (typical for USB/cloud).
- Commands: `ifup ens192`, `ifdown ens192`, `ifquery --state`, `systemctl restart networking` (⚠️ restarts *all* interfaces: risky over SSH).
- `source /etc/network/interfaces.d/*` at the top lets you split configs into files.

⚠️ Debian installs NetworkManager on desktop tasks; then NetworkManager ignores any interface listed in `/etc/network/interfaces` (except `lo`). Two managers, one interface = chaos. Pick one.

### 14.5 ifcfg files 🔴 (RHEL ≤ 8, still on many servers)

`/etc/sysconfig/network-scripts/ifcfg-ens192`:

```ini
TYPE=Ethernet
NAME=ens192
DEVICE=ens192
ONBOOT=yes
BOOTPROTO=none        # none/static = static; dhcp = DHCP
IPADDR=192.168.10.50
PREFIX=24             # or NETMASK=255.255.255.0
GATEWAY=192.168.10.1
DNS1=192.168.10.1
DNS2=1.1.1.1
DOMAIN=example.lan
DEFROUTE=yes
IPV6INIT=yes
```

Extra routes: `/etc/sysconfig/network-scripts/route-ens192` with lines like `10.20.0.0/16 via 192.168.10.254`.
Apply: `nmcli connection reload && nmcli connection up ens192` (RHEL 7/8 with NM) or `systemctl restart network` (RHEL 6, or 7/8 with the legacy `network` service).
Global settings: `/etc/sysconfig/network` (`GATEWAY=`, `HOSTNAME=` on RHEL 6).

### 14.6 wicked 🟡 (SUSE)

Same `ifcfg-*` file style, in `/etc/sysconfig/network/`. Routes go in `/etc/sysconfig/network/routes` (global) or `ifroute-ens192`. DNS in `/etc/sysconfig/network/config` (`NETCONFIG_DNS_STATIC_SERVERS=`), then `netconfig update -f`.

```bash
wicked ifstatus all
wicked ifup ens192 / ifdown ens192
wicked show-config
yast lan               # text-mode YaST network module
```

SLE 16 and current openSUSE moved to NetworkManager by default; know both for SUSE exams.

### 14.7 DHCP clients

| Client | Where |
|---|---|
| NetworkManager's internal client | RHEL/Fedora default (`dhcp=internal`) |
| systemd-networkd's built-in client | networkd/netplan |
| `dhclient` 🟡 (ISC, end-of-life upstream) | Debian/Ubuntu classic; `/etc/dhcp/dhclient.conf`, leases in `/var/lib/dhcp/` |
| `dhcpcd` | Raspberry Pi OS (older), Arch option |

Manual tests:

```bash
sudo dhclient -v ens192          # get a lease, verbose
sudo dhclient -r ens192          # release
sudo nmcli device reapply ens192 # or: nmcli connection up ens192 (renews)
sudo tcpdump -ni ens192 port 67 or port 68 -vvv   # watch DISCOVER/OFFER/REQUEST/ACK ("DORA")
```

DHCP servers: `dnsmasq` (small), ISC `dhcpd` 🔴 (EOL), **Kea** 🟢 (ISC's replacement, `/etc/kea/kea-dhcp4.conf` JSON).

---

## 15. Firewalls: nftables, iptables, firewalld, ufw

### 15.1 The layer cake

```
   ufw (Ubuntu)      firewalld (RHEL/Fedora/SUSE)     hand-written rules
       │                       │                             │
   iptables-nft              nftables                   nft / iptables
       └────────────┬──────────┴──────────────────────────────┘
                    │
              Linux kernel netfilter
```

- **netfilter** is the kernel engine.
- **iptables** 🟡 is the old command language (tables: filter, nat, mangle, raw; chains: INPUT, OUTPUT, FORWARD, PREROUTING, POSTROUTING).
- **nftables** 🟢 (`nft`) replaced iptables in the kernel and in most distros (Debian 10+, RHEL 8+, Ubuntu 20.10+ backend).
- **firewalld** 🟢 is a friendly service with "zones" on top of nftables. Default on RHEL family, Fedora, SUSE.
- **ufw** 🟢 ("uncomplicated firewall") is a simple front-end on Ubuntu, using iptables-nft.

✅ Use **one** of them. Mixing ufw + firewalld + raw nft rules leads to rules that vanish or conflict.

### 15.2 firewalld 🟢

Zones = trust levels assigned to interfaces or source IPs. Default zone is usually `public`.

```bash
sudo firewall-cmd --state
sudo firewall-cmd --get-active-zones                 # which zone is each interface in?
sudo firewall-cmd --get-default-zone
sudo firewall-cmd --list-all                         # rules in the default zone
sudo firewall-cmd --list-all --zone=internal
sudo firewall-cmd --get-services                     # known service names

# Open things (runtime only!)
sudo firewall-cmd --add-service=http
sudo firewall-cmd --add-port=8080/tcp
sudo firewall-cmd --add-service=https --permanent    # persistent, but NOT active until reload
sudo firewall-cmd --reload                           # load permanent config into runtime
sudo firewall-cmd --runtime-to-permanent             # the other direction: save what you tested

# Remove
sudo firewall-cmd --remove-service=http --permanent
sudo firewall-cmd --remove-port=8080/tcp --permanent

# Zones
sudo firewall-cmd --zone=internal --change-interface=ens224 --permanent
sudo firewall-cmd --set-default-zone=drop
sudo firewall-cmd --zone=trusted --add-source=192.168.10.0/24 --permanent

# Rich rules (more detail)
sudo firewall-cmd --permanent --add-rich-rule='rule family=ipv4 source address=203.0.113.0/24 port port=22 protocol=tcp accept'
sudo firewall-cmd --permanent --add-rich-rule='rule family=ipv4 source address=198.51.100.7 reject'

# NAT / masquerade (make this box share its internet)
sudo firewall-cmd --zone=public --add-masquerade --permanent
# Port forward 8080 → 80 on another host
sudo firewall-cmd --permanent --add-forward-port=port=8080:proto=tcp:toport=80:toaddr=10.20.0.9

# Emergency: block everything
sudo firewall-cmd --panic-on   # (--panic-off to undo)
```

⚠️ **The #1 firewalld gotcha:** `--permanent` changes do nothing until `--reload`, and runtime changes without `--permanent` vanish on reload/reboot. Best habit: test at runtime, then `--runtime-to-permanent`.

⚠️ Which zone an interface lands in comes from the NetworkManager profile (`connection.zone`); if unset, the default zone.

Custom services: copy `/usr/lib/firewalld/services/http.xml` to `/etc/firewalld/services/myapp.xml`, edit, `--reload`.

### 15.3 ufw 🟢 (Ubuntu)

```bash
sudo ufw status verbose
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow ssh                     # or: allow 22/tcp  (⚠️ do this BEFORE enabling over SSH!)
sudo ufw allow 80,443/tcp
sudo ufw allow from 192.168.10.0/24 to any port 3306 proto tcp
sudo ufw limit ssh                     # rate-limit: blocks brute-force (6 attempts / 30 s)
sudo ufw deny from 198.51.100.7
sudo ufw allow in on ens224 to any port 2049
sudo ufw enable                        # persistent, starts at boot
sudo ufw status numbered
sudo ufw delete 3                      # delete rule number 3
sudo ufw disable
sudo ufw reset                         # wipe everything
sudo ufw logging on; tail -f /var/log/ufw.log
```

App profiles: `ufw app list`, `ufw allow "Nginx Full"`. Files: `/etc/ufw/*.rules`, `/etc/default/ufw` (IPv6 on/off), `/etc/ufw/sysctl.conf`. Forwarding/NAT needs `DEFAULT_FORWARD_POLICY="ACCEPT"` and a `*nat` block in `/etc/ufw/before.rules`.

### 15.4 nftables 🟢 (`nft`)

The modern native language. One config file: `/etc/nftables.conf` (Debian/Ubuntu) or `/etc/sysconfig/nftables.conf` (RHEL), service `nftables`.

```bash
sudo nft list ruleset                    # show everything (also shows what firewalld/iptables-nft created)
sudo nft list tables
sudo nft list table inet filter
sudo nft flush ruleset                   # delete everything (⚠️ over SSH: make sure default policy isn't drop first)
sudo nft -f /etc/nftables.conf           # load from file
sudo nft -c -f /etc/nftables.conf        # check syntax only
sudo nft monitor                         # watch changes live
```

A complete basic server firewall (`/etc/nftables.conf`):

```nft
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
    set admins {
        type ipv4_addr
        flags interval
        elements = { 192.168.10.0/24, 203.0.113.5 }
    }

    chain input {
        type filter hook input priority 0; policy drop;

        iif "lo" accept
        ct state established,related accept
        ct state invalid drop
        ip protocol icmp accept
        ip6 nexthdr icmpv6 accept
        tcp dport 22 ip saddr @admins accept
        tcp dport { 80, 443 } accept
        udp dport 53 accept
        limit rate 5/minute log prefix "nft-drop: "
    }

    chain forward {
        type filter hook forward priority 0; policy drop;
    }

    chain output {
        type filter hook output priority 0; policy accept;
    }
}

# NAT example (router)
table ip nat {
    chain postrouting {
        type nat hook postrouting priority 100;
        oifname "ens192" masquerade
    }
    chain prerouting {
        type nat hook prerouting priority -100;
        tcp dport 8080 dnat to 10.20.0.9:80
    }
}
```

Enable: `sudo systemctl enable --now nftables`.

Key ideas: `inet` family handles IPv4 and IPv6 in one table; **sets** (`{ 80, 443 }`, named sets) replace dozens of iptables lines; `ct state` is connection tracking; one rule can `log` and `accept`.

Live edits:

```bash
sudo nft add rule inet filter input tcp dport 8080 accept
sudo nft -a list chain inet filter input      # show handles (rule numbers)
sudo nft delete rule inet filter input handle 12
sudo nft add element inet filter admins { 10.0.0.7 }
```

### 15.5 iptables 🟡/🔴 (know it cold for exams and old servers)

```bash
sudo iptables -L -n -v --line-numbers          # list filter table
sudo iptables -t nat -L -n -v                  # NAT table
sudo iptables -S                               # rules as commands (great for saving)

# Basic host firewall
sudo iptables -P INPUT DROP
sudo iptables -P FORWARD DROP
sudo iptables -P OUTPUT ACCEPT
sudo iptables -A INPUT -i lo -j ACCEPT
sudo iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
sudo iptables -A INPUT -p icmp -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 22 -s 192.168.10.0/24 -j ACCEPT
sudo iptables -A INPUT -p tcp -m multiport --dports 80,443 -j ACCEPT
sudo iptables -A INPUT -j LOG --log-prefix "ipt-drop: " -m limit --limit 5/min
sudo iptables -I INPUT 1 -s 198.51.100.7 -j DROP     # -I inserts at the top; -A appends at the bottom
sudo iptables -D INPUT 3                              # delete rule 3
sudo iptables -F                                      # flush (⚠️ with policy DROP you lock yourself out)

# NAT
sudo iptables -t nat -A POSTROUTING -o ens192 -j MASQUERADE
sudo iptables -t nat -A PREROUTING -p tcp --dport 8080 -j DNAT --to-destination 10.20.0.9:80
sudo iptables -A FORWARD -i ens224 -o ens192 -j ACCEPT

# Save / restore
sudo iptables-save > /etc/iptables/rules.v4          # Debian/Ubuntu (package iptables-persistent / netfilter-persistent)
sudo iptables-restore < /etc/iptables/rules.v4
sudo service iptables save                            # RHEL ≤7 with iptables-services (/etc/sysconfig/iptables)
ip6tables ...                                          # separate command for IPv6!
iptables -V                                            # shows "(nf_tables)" = you're really using nftables underneath
iptables-translate -A INPUT -p tcp --dport 22 -j ACCEPT   # convert a rule to nft syntax
```

Rule order matters: **first match wins.** DROP silently discards; REJECT sends an error back (nicer for internal networks, DROP for the internet).

⚠️ `iptables-legacy` vs `iptables-nft`: if Docker or an old script uses one and you use the other, `iptables -L` may not show all rules. `nft list ruleset` shows everything. `update-alternatives --config iptables` switches on Debian/Ubuntu.

⚠️ Docker rewrites iptables (chain `DOCKER`, `DOCKER-USER`) and can expose container ports past ufw. Put your restrictions in `DOCKER-USER` or set `"iptables": false` in `/etc/docker/daemon.json` (advanced).

### 15.6 Other security tools

- `fail2ban`: reads logs, bans IPs that fail logins (`fail2ban-client status sshd`).
- TCP Wrappers (`/etc/hosts.allow`, `/etc/hosts.deny`) 🔴: removed from most distros (RHEL 8+); sshd no longer supports it.
- SELinux (RHEL) / AppArmor (Ubuntu/SUSE): can block a service from binding a non-standard port. `semanage port -a -t http_port_t -p tcp 8080` on RHEL. `ausearch -m avc -ts recent` to see denials.

---

## 16. Advanced Interfaces: VLANs, Bridges, Bonds

### 16.1 VLANs (802.1Q)

A VLAN tag lets one cable carry several separate networks. The switch port must be a "trunk."

```bash
# Temporary
sudo ip link add link ens192 name ens192.100 type vlan id 100
sudo ip addr add 192.168.100.5/24 dev ens192.100
sudo ip link set ens192.100 up
ip -d link show ens192.100           # -d shows "vlan id 100"

# NetworkManager
sudo nmcli connection add type vlan con-name vlan100 ifname ens192.100 dev ens192 id 100 \
  ipv4.method manual ipv4.addresses 192.168.100.5/24
```

⚠️ If VLAN traffic never arrives, 90% of the time the switch port isn't configured as a trunk, or the VLAN isn't allowed on that trunk. Verify with `tcpdump -e vlan`.
🔴 `vconfig add ens192 100` is the ancient way.

### 16.2 Bridges

A bridge is a software switch. Used for VMs and containers (`virbr0`, `docker0`, `br0`).

```bash
# Temporary
sudo ip link add br0 type bridge
sudo ip link set ens192 master br0
sudo ip link set br0 up
bridge link                          # 🟢 show ports (package iproute2)
bridge fdb show                      # MAC table
brctl show                           # 🔴 legacy (bridge-utils)

# NetworkManager
sudo nmcli connection add type bridge con-name br0 ifname br0 ipv4.method manual ipv4.addresses 192.168.10.50/24 ipv4.gateway 192.168.10.1
sudo nmcli connection add type ethernet con-name br0-port1 ifname ens192 master br0
sudo nmcli connection up br0
```

⚠️ When you put `ens192` into a bridge, the **IP address moves to `br0`**, not the physical interface. Forgetting this kills your SSH session.
⚠️ In VMware/cloud, the hypervisor may block bridged/promiscuous traffic ("MAC address changes" / "forged transmits" must be allowed).

### 16.3 Bonding (link aggregation) and teaming

Combine two NICs for redundancy and/or speed.

| Mode | Number | What it does | Switch config needed? |
|---|---|---|---|
| `active-backup` | 1 | One active, one standby. Simplest, safest. | No |
| `balance-rr` | 0 | Round-robin, can reorder packets | Static channel group |
| `balance-xor` | 2 | Hash-based | Static channel group |
| `broadcast` | 3 | Send on all | Rarely used |
| `802.3ad` (LACP) | 4 | Standard aggregation, load-balanced | **Yes (LACP)** |
| `balance-tlb` | 5 | Adaptive transmit balancing | No |
| `balance-alb` | 6 | Adaptive both directions | No |

```bash
# NetworkManager
sudo nmcli connection add type bond con-name bond0 ifname bond0 bond.options "mode=active-backup,miimon=100" \
  ipv4.method manual ipv4.addresses 192.168.10.50/24 ipv4.gateway 192.168.10.1
sudo nmcli connection add type ethernet con-name bond0-port1 ifname ens256 master bond0
sudo nmcli connection add type ethernet con-name bond0-port2 ifname ens257 master bond0
sudo nmcli connection up bond0

# Check
cat /proc/net/bonding/bond0          # active slave, link status, LACP partner info
ip -d link show bond0
```

`miimon=100` = check link every 100 ms. For LACP add `lacp_rate=fast,xmit_hash_policy=layer3+4`.

**Teaming** (`teamd`, `nmcli ... type team`) was RHEL 7/8's alternative; it is **deprecated in RHEL 9 and removed in RHEL 10.** Use bonding. `nmcli connection migrate` or `team2bond` helps convert.

### 16.4 Network namespaces (containers' secret)

Each namespace has its own interfaces, routes, and firewall. Docker and Kubernetes use them.

```bash
sudo ip netns add test
sudo ip netns list
sudo ip link add veth0 type veth peer name veth1        # a virtual cable
sudo ip link set veth1 netns test
sudo ip addr add 10.99.0.1/24 dev veth0 && sudo ip link set veth0 up
sudo ip netns exec test ip addr add 10.99.0.2/24 dev veth1
sudo ip netns exec test ip link set veth1 up
sudo ip netns exec test ip link set lo up
sudo ip netns exec test ping -c 2 10.99.0.1
sudo ip netns exec test bash                            # a shell "inside" the namespace
sudo ip netns del test
```

Also: `nsenter -t <PID> -n ss -tulnp` to look inside a running container's network.

### 16.5 Tunnels and VPNs (quick tour)

- **WireGuard** 🟢: modern, simple, in the kernel. `wg`, `wg-quick up wg0`, `/etc/wireguard/wg0.conf`. `nmcli connection import type wireguard file wg0.conf`.
- **OpenVPN** 🟡: `openvpn --config client.ovpn`, `tun0` interface.
- **IPsec**: strongSwan / Libreswan (`ipsec status`).
- GRE/IPIP tunnels: `ip tunnel add gre1 mode gre remote X local Y`.
- `ip xfrm` for raw IPsec state.

---

## 17. IPv6 Essentials

IPv6 is not optional anymore; exams cover it.

- Addresses are 128 bits, written in hex: `2001:0db8:0000:0000:0000:0000:0000:0005` → `2001:db8::5` (leading zeros dropped, one run of zeros replaced by `::`).
- `fe80::/10` = link-local, automatic on every interface, only valid on that cable. When using it you must add the interface: `ping fe80::1%ens192`.
- `::1` = loopback. `2000::/3` = public internet. `fc00::/7` (`fd..`) = private (ULA).
- No broadcast; multicast instead (`ff02::1` = all hosts on the link).
- **SLAAC** = the router advertises the prefix and hosts make their own address. **DHCPv6** = like DHCP. Often both.
- ICMPv6 is **required** (neighbor discovery, path MTU): **never block all ICMPv6** in a firewall.

```bash
ip -6 addr
ip -6 route
ip -6 neigh
ping -6 2001:4860:4860::8888
ping6 -I ens192 ff02::1                 # find all IPv6 hosts on the link
dig AAAA example.com
sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1      # disable (temporary); prefer leaving it on
nmcli connection modify ens192 ipv6.method disabled  # disable per connection
ip6tables -L / nft list ruleset                       # firewall: inet family covers both
```

⚠️ Apps may prefer IPv6 (`AAAA` record exists) and hang if IPv6 is half-broken. Test with `curl -6 -v`. `/etc/gai.conf` tunes preference.
⚠️ `ss -tulnp` shows `[::]:22`: that usually means IPv4 **and** IPv6 (dual-stack socket).

---

## 18. Logs and Kernel Settings

```bash
journalctl -u NetworkManager -f            # follow NM logs
journalctl -u systemd-networkd -b          # since boot
journalctl -u systemd-resolved
journalctl -u sshd -f
journalctl -k | grep -iE "eth|ens|link|nic"   # kernel messages about links
dmesg -T | grep -i "link is"               # "Link is Up 1000 Mbps Full Duplex"
tail -f /var/log/syslog /var/log/messages  # classic logs (Debian / RHEL)
tail -f /var/log/firewalld /var/log/ufw.log
```

**sysctl** kernel tunables (`/proc/sys/net/`). View: `sysctl -a | grep net.ipv4`. Set temporarily: `sysctl -w key=value`. Persist: files in `/etc/sysctl.d/*.conf`, then `sysctl --system`.

| Key | Purpose |
|---|---|
| `net.ipv4.ip_forward=1` | Router mode |
| `net.ipv6.conf.all.forwarding=1` | IPv6 router mode |
| `net.ipv4.conf.all.rp_filter=1` | Reverse path filter (anti-spoofing); set to `2` (loose) or `0` for asymmetric/policy routing |
| `net.ipv4.icmp_echo_ignore_all=1` | Ignore pings |
| `net.ipv4.tcp_syncookies=1` | SYN flood protection |
| `net.core.somaxconn`, `net.ipv4.tcp_max_syn_backlog` | Connection queue sizes for busy servers |
| `net.ipv4.ip_local_port_range` | Ephemeral (client) ports |
| `net.ipv4.tcp_fin_timeout`, `tcp_tw_reuse` | TIME_WAIT tuning |
| `net.core.rmem_max`, `wmem_max` | Socket buffer sizes (high bandwidth × latency links) |
| `net.ipv4.conf.all.accept_redirects=0`, `send_redirects=0` | Hardening |
| `net.ipv6.conf.all.accept_ra` | Accept IPv6 router advertisements (set 2 when forwarding is on) |

⚠️ `rp_filter=1` silently drops packets in multi-homed/asymmetric setups. If a packet arrives on interface A but the route back is via B, it's dropped. Check with `tcpdump` (packet arrives) vs. `ss`/app (never sees it). Also see `/proc/net/snmp` or `nstat -az | grep -i rpfilter`.

Statistics: `nstat`, `ss -s`, `cat /proc/net/dev`, `sar -n DEV 1` (sysstat), `ip -s -s link`.

---

## 19. Remote Access: SSH Tools

```bash
ssh user@host                          # log in
ssh -p 2222 user@host                  # non-standard port
ssh -v user@host                       # verbose: debug key/auth problems (-vvv for more)
ssh-keygen -t ed25519 -C "me@laptop"   # make a key (ed25519 is the modern choice)
ssh-copy-id user@host                  # install your public key on the server
ssh -L 8080:localhost:80 user@host     # local port forward: my :8080 → server's :80
ssh -R 9000:localhost:3000 user@host   # remote port forward: server's :9000 → my :3000
ssh -D 1080 user@host                  # SOCKS proxy through the server
ssh -J jumphost user@internal          # jump host (bastion)
ssh -N -f ...                          # no shell, background (for tunnels)
scp file user@host:/tmp/               # copy files (uses SFTP protocol in modern OpenSSH)
sftp user@host
rsync -avz --progress dir/ user@host:/backup/dir/   # smarter copy
```

`~/.ssh/config` saves typing:

```
Host web01
    HostName 192.168.10.50
    User admin
    Port 22
    IdentityFile ~/.ssh/id_ed25519
    ProxyJump bastion.example.com
```

Server side: `/etc/ssh/sshd_config` (and `sshd_config.d/*.conf`). Key hardening: `PermitRootLogin no`, `PasswordAuthentication no`, `AllowUsers admin`. Always `sshd -t` to test the config, then `systemctl reload sshd` (or `ssh` on Debian/Ubuntu). **Keep your current session open while testing a new one** in case you locked yourself out.

⚠️ SSH permissions: `~/.ssh` must be `700`, `authorized_keys` `600`, home dir not group-writable, or key login silently fails (check `journalctl -u sshd`).
⚠️ On RHEL, SELinux blocks sshd on a non-standard port until `semanage port -a -t ssh_port_t -p tcp 2222`. On Ubuntu 22.10+, sshd is socket-activated: changing `Port` requires editing `ssh.socket` or `systemctl daemon-reload && systemctl restart ssh.socket`.

Other remote tools: `mosh` (SSH that survives roaming/lag), `tmux`/`screen` (keep sessions alive; ✅ always use one when doing network changes remotely).

---

## 20. Distribution Cheat Sheet

| Task | RHEL / Rocky / Alma / Fedora | Debian | Ubuntu Server | SUSE / openSUSE | Arch |
|---|---|---|---|---|---|
| Default manager | NetworkManager | ifupdown (server), NM (desktop) | Netplan → networkd | wicked (SLE ≤15) / NM (SLE 16, desktop) | networkd or NM (your choice) |
| Config files | `/etc/NetworkManager/system-connections/` | `/etc/network/interfaces` | `/etc/netplan/*.yaml` | `/etc/sysconfig/network/ifcfg-*` | `/etc/systemd/network/` |
| Apply | `nmcli con up X` | `ifup X` / `systemctl restart networking` | `netplan apply` | `wicked ifup X` / `yast lan` | `networkctl reload` |
| Firewall default | firewalld (nftables) | nftables (nothing enabled by default) | ufw (installed, disabled by default) | firewalld | none (nftables/iptables available) |
| DNS resolver | systemd-resolved (Fedora) / NM writes resolv.conf (RHEL) | plain resolv.conf or resolvconf | systemd-resolved | netconfig | your choice |
| `dig` package | `bind-utils` | `bind9-dnsutils` | `bind9-dnsutils` | `bind-utils` | `bind` |
| `ss`/`ip` package | `iproute` | `iproute2` | `iproute2` | `iproute2` | `iproute2` |
| `ifconfig`/`netstat` package | `net-tools` (not installed) | `net-tools` (not installed) | `net-tools` (not installed) | `net-tools-deprecated` | `net-tools` |
| `nc` flavor | `nmap-ncat` | OpenBSD `netcat-openbsd` | OpenBSD | OpenBSD/`ncat` | OpenBSD or GNU |
| `traceroute` | `traceroute` | `traceroute` / `inetutils-traceroute` | `traceroute` | `traceroute` | `traceroute` |
| Package tool | `dnf` (`yum`) | `apt` | `apt` | `zypper` | `pacman` |
| Hosts entry for own name | `127.0.0.1` line | `127.0.1.1 hostname` | `127.0.1.1 hostname` | `127.0.0.1` line | manual |
| SSH service name | `sshd` | `ssh` | `ssh` | `sshd` | `sshd` |
| MAC security | SELinux | AppArmor (optional) | AppArmor | AppArmor | none default |
| Certs | `update-ca-trust` | `update-ca-certificates` | `update-ca-certificates` | `update-ca-certificates` | `trust extract-compat` |

Install the troubleshooting toolkit:

```bash
# RHEL family
sudo dnf install -y iproute bind-utils nmap-ncat tcpdump mtr traceroute nmap iperf3 ethtool lsof telnet net-tools
# Debian / Ubuntu
sudo apt install -y iproute2 bind9-dnsutils netcat-openbsd tcpdump mtr-tiny traceroute nmap iperf3 ethtool lsof net-tools
# SUSE
sudo zypper install -y iproute2 bind-utils netcat-openbsd tcpdump mtr traceroute nmap iperf ethtool lsof
# Arch
sudo pacman -S iproute2 bind openbsd-netcat tcpdump mtr traceroute nmap iperf3 ethtool lsof
```

---

## 21. Gotchas: Things That Trip People Up

1. **Temporary vs. persistent.** `ip addr add` disappears at reboot. Use the network manager for anything that must stay.
2. **Two managers, one interface.** NetworkManager + `/etc/network/interfaces`, or networkd + NetworkManager both claiming `ens192`. Symptoms: settings flip-flop. Fix: `nmcli device set X managed no` or remove one config.
3. **`/etc/resolv.conf` overwritten.** See Section 9. Edit the source, not the generated file.
4. **`--permanent` without `--reload`** in firewalld, and runtime rules without `--permanent`.
5. **Locking yourself out over SSH.** Changing the IP, the firewall, or bringing the interface down. Use `netplan try`, `tmux`, an `at now + 5 min` job that restores config, `iptables ... ; sleep 60; iptables -F` patterns, or a console (IPMI/VM console).
6. **Missing prefix length** (`/24`) gives a `/32` and no neighbors.
7. **Interface name changed** after cloning a VM or moving a NIC to a new slot.
8. **Duplex mismatch** and **duplicate IPs** (Sections 6.3, 8).
9. **MTU / fragmentation** on VPNs and tunnels: small packets work, big ones hang.
10. **rp_filter** drops asymmetric traffic silently.
11. **Service bound to 127.0.0.1** so remote clients can't connect (check `ss -tlnp`).
12. **SELinux/AppArmor** blocking non-standard ports or paths. Check `ausearch`/`dmesg`.
13. **`dig` works but the app doesn't** (or the reverse): nsswitch and `/etc/hosts`. Use `getent hosts`.
14. **IPv6 half-configured** causing timeouts before IPv4 fallback.
15. **cloud-init** resetting hostname/netplan at boot.
16. **Docker punching holes** through ufw/firewalld.
17. **Proxy environment variables** breaking `curl`/`apt` but not `ping`.
18. **ICMP blocked** ≠ host down.
19. **DHCP lease keeps your old DNS** after you set static DNS (`ipv4.ignore-auto-dns yes` / `use-dns: false`).
20. **Netplan YAML tabs** and file permissions.
21. **`hostname` vs `hostnamectl`**: one is temporary.
22. **Ports < 1024 need root** (or capabilities).
23. **`iptables-legacy` vs `iptables-nft`** showing different rule sets.
24. **Time drift** breaks TLS, Kerberos, and logs correlation: keep `chronyd`/`systemd-timesyncd` running (`chronyc sources`, `timedatectl`).
25. **`systemctl restart networking`** on Debian bounces every interface, including the one you're SSH'd over.
26. **Wait-online delays** at boot: a NIC without link causes `systemd-networkd-wait-online` or `NetworkManager-wait-online` to stall 2 minutes. Mark it `optional: true` / disable autoconnect.

---

## 22. Best Practices

✅ **Learn `ip`, `ss`, `nft`, `nmcli`, `dig`, `tcpdump` first.** They work on every modern distro.
✅ **Always use `-n`** with `ss`, `tcpdump`, `traceroute`, `iptables -L` unless you truly want names; DNS lookups make tools slow and misleading.
✅ **Test before persist:** `netplan try`, firewalld runtime then `--runtime-to-permanent`, `nft -c -f`, `sshd -t`, `named-checkconf`.
✅ **Keep a safety net for remote changes:** `tmux`, out-of-band console, scheduled rollback (`echo "nmcli con up old" | at now + 5 minutes`).
✅ **One network manager per interface. One firewall front-end per host.**
✅ **Document your config in the config files** (comments in YAML/keyfiles/nft) and keep them in version control (`etckeeper` or git).
✅ **Default deny inbound, allow what you need, allow SSH from limited sources, rate-limit SSH.** Always allow loopback and established/related.
✅ **Never block all ICMP** (especially ICMPv6). Allow at least echo, destination-unreachable, time-exceeded, packet-too-big.
✅ **Use `/etc/hosts` for the machine's own name** so `sudo`, `hostname -f`, and many services stay happy when DNS is down.
✅ **Set static DNS via the manager**, not by editing resolv.conf.
✅ **Bond for redundancy** (`active-backup` if the switch team can't do LACP).
✅ **Match speed/duplex settings on both ends** (prefer auto/auto).
✅ **Use `active-backup` or LACP; avoid `balance-rr`** unless you know why you need it.
✅ **Use SSH keys (ed25519), disable password auth, don't allow root login.**
✅ **Prefer nftables `inet` tables** so IPv4 and IPv6 rules stay in sync.
✅ **Use `getent hosts`** when reproducing what an application sees.
✅ **Capture packets at both ends** when in doubt.
✅ **Log dropped packets with rate limits** so you can see attacks without filling the disk.
✅ **Keep time synced** (chrony).
✅ **Label your cables** and use `ethtool -p` to find ports.
✅ **Use `ip -j` + `jq` in scripts**, never parse `ifconfig` output.
✅ **Before an exam, practice each task on RHEL-family AND Debian/Ubuntu**, because the file paths differ.

---

## 23. The Troubleshooting Ladder

Work bottom-up. Stop at the first broken rung.

```
1. Link:      ip -br link         → is the interface UP and LOWER_UP? (not NO-CARRIER)
                ethtool ens192    → "Link detected: yes", sane speed/duplex
                dmesg | grep -i link
2. Address:   ip -br addr         → correct IP and prefix? DHCP lease? (journalctl -u NetworkManager)
3. Neighbors: ip neigh            → gateway shows a MAC, state REACHABLE? (arping -I ens192 GATEWAY)
4. Routes:    ip route            → default route present? ip route get 8.8.8.8 picks the right interface?
5. Gateway:   ping -c3 GATEWAY
6. Beyond:    ping -c3 1.1.1.1    → works = internet OK, DNS may be the issue
                mtr 1.1.1.1       → where does it break?
7. DNS:       resolvectl status / cat /etc/resolv.conf
                dig example.com   → status NOERROR? which SERVER answered?
                getent hosts example.com
8. Service:   ss -tulnp           → is it listening? on 0.0.0.0 or only 127.0.0.1?
                nc -zv HOST PORT  → reachable from outside?
                curl -v http://HOST:PORT
9. Firewall:  firewall-cmd --list-all / ufw status / nft list ruleset / iptables -L -n -v
                (look at packet counters going up on a DROP rule)
10. Deeper:   tcpdump -ni ens192 host X and port Y  → do packets arrive? do replies leave?
                journalctl -u SERVICE, ausearch -m avc (SELinux), dmesg
                sysctl rp_filter, MTU tests (ping -M do -s 1472)
```

Common patterns:

| Symptom | Likely cause | Check |
|---|---|---|
| `Destination Host Unreachable` | No route, or ARP fails (wrong VLAN, bad cable, wrong subnet) | `ip route`, `ip neigh`, `arping` |
| `Network is unreachable` | No default route | `ip route` |
| Ping by IP works, by name fails | DNS | `dig`, `resolvectl`, `/etc/resolv.conf` |
| `Connection refused` | Nothing listening on that port, or REJECT firewall rule | `ss -tlnp` on the server |
| Connection hangs / times out | DROP firewall rule, wrong route, or host down | `nc -zv`, `tcpdump`, firewall counters |
| Works locally, not remotely | Service bound to 127.0.0.1, or firewall | `ss -tlnp` |
| SSH connects then freezes; big pages hang | MTU | `ping -M do -s 1472` |
| Slow, high errors, collisions | Duplex mismatch, bad cable | `ethtool`, `ethtool -S`, `ip -s link` |
| Intermittent drops | Duplicate IP, flapping bond, Wi-Fi | `arping -D`, `/proc/net/bonding/`, `mtr` |
| Setting vanishes after reboot | Temporary command used, or wrong manager's file edited | `systemctl status NetworkManager systemd-networkd networking` |
| Only IPv4 or only IPv6 works | Dual-stack misconfig | `curl -4`/`-6 -v` |
| `Permission denied` binding a port | Port < 1024 as non-root, or SELinux | run as root / capabilities / `semanage port` |

---

## 24. Hands-On Labs

Do these on a VM you can break. Each lab lists the goal, the steps, and how you know you succeeded. Two VMs on the same virtual network (or one VM plus its host) are ideal.

### Lab 1: Explore your system (15 min)

1. Run `ip -br link`, `ip -br addr`, `ip route`, `ip neigh`, `ss -tulnp`, `cat /etc/resolv.conf`, `hostnamectl`.
2. Identify: your interface name, IP/prefix, gateway, DNS servers, hostname, and which manager is active (`systemctl is-active NetworkManager systemd-networkd networking wicked`).
3. Run `ip route get 1.1.1.1` and explain every field in the output.
4. Run `ethtool <iface>` (or `sudo ethtool`) and note speed, duplex, and "Link detected."
5. Write down which config file(s) control this interface.

**Success:** you can draw your machine's network setup on paper from memory.

### Lab 2: Temporary changes and why they vanish (15 min)

1. `sudo ip addr add 192.168.10.99/24 dev <iface>` (use an unused IP in your subnet).
2. `ip -br addr` to see it. From another machine, `ping` the new IP.
3. `sudo ip route add 10.123.0.0/16 via <gateway>`; verify with `ip route`.
4. Reboot. Check `ip addr` and `ip route`: the changes are gone.
5. Now add the same second IP persistently with your distro's manager (`nmcli`, netplan, `.network`, or `interfaces`). Reboot and verify it stays.

**Success:** you can explain the difference between runtime and persistent state.

### Lab 3: Static IP on every distro family (30 min)

Use the Quick Start (Section 2). If you only have one distro, do it three ways anyway on that VM: with `nmcli`, then with `nmtui`, then by writing the keyfile/YAML by hand and reloading. Switch back to DHCP at the end.

**Success:** static IP survives reboot; `ping` to gateway, internet IP, and a DNS name all work.

### Lab 4: DNS deep dive (20 min)

1. `ls -l /etc/resolv.conf` and figure out who generates it.
2. `dig example.com`, `dig +short example.com MX`, `dig -x 1.1.1.1`, `dig @9.9.9.9 example.com`, `dig +trace example.com`.
3. Add `1.2.3.4 fake.test` to `/etc/hosts`. Compare `dig fake.test` (fails) and `getent hosts fake.test` (works). Explain why.
4. Change your DNS server to `9.9.9.9` the *proper* way for your manager. Confirm with `resolvectl status` or `cat /etc/resolv.conf` and `dig` output's `SERVER:` line.
5. Break DNS on purpose (set nameserver to `192.0.2.1`). Observe `ping 1.1.1.1` still works but `ping example.com` fails. Fix it.

**Success:** you can diagnose "DNS is broken" in under a minute.

### Lab 5: Ports, sockets, and a fake service (20 min)

1. On VM A: `nc -l 9000` (or `python3 -m http.server 8000`).
2. On VM A: `ss -tlnp` and find your listener. Note whether it's on `0.0.0.0`, `*`, or `127.0.0.1`.
3. On VM B: `nc -zv A 9000`, then `nc A 9000` and type a message. Watch it appear on A.
4. On VM A: `sudo lsof -i :9000` and `sudo fuser -n tcp 9000`.
5. Start something bound only to localhost: `nc -l 127.0.0.1 9001`. Try to reach it from B. Explain the failure.

**Success:** you understand "listening address" vs "port."

### Lab 6: Firewall (30 min)

Pick the front-end for your distro (firewalld on RHEL/SUSE, ufw on Ubuntu, raw nftables on Debian/Arch).

1. Keep Lab 5's listener running on A on port 9000. Confirm B can reach it.
2. Enable the firewall with SSH allowed **first** (`ufw allow ssh` / firewalld allows ssh by default / nft rule for port 22). Then set default deny inbound.
3. From B: `nc -zv A 9000` should now hang/fail. `ping A` (may still work).
4. Open port 9000 at runtime only (firewalld: `--add-port=9000/tcp`; ufw: `allow 9000/tcp`; nft: `nft add rule ...`). Test from B. Works.
5. Reboot A (or `firewall-cmd --reload`). Test from B. On firewalld it fails again: you forgot `--permanent`. Fix it properly.
6. Add a rule allowing port 9000 only from B's IP, and test from a third address (or from A's own second IP) that it's blocked.
7. Look at `sudo nft list ruleset` and find the rule the front-end created.
8. Add a logging rule for dropped packets and watch `journalctl -k -f` while B tries a blocked port.

**Success:** you can open, restrict, persist, and prove a firewall rule.

### Lab 7: Packet capture (20 min)

1. On A: `sudo tcpdump -ni <iface> icmp`. On B: `ping -c 3 A`. Watch request/reply pairs.
2. On A: `sudo tcpdump -ni <iface> port 53`. On A in another terminal: `dig example.com`. Identify the query and the response.
3. On A: `sudo tcpdump -ni <iface> 'tcp port 9000'`. From B: `nc -zv A 9000`. Identify the `[S]`, `[S.]`, `[.]` handshake, then `[F.]`/`[R]`.
4. Block 9000 in the firewall with DROP and repeat step 3: see `[S]` retries with no reply. Switch to REJECT: see `[R]` or ICMP unreachable.
5. Save a capture (`-w lab.pcap`), copy it to your laptop with `scp`, open in Wireshark, use "Follow TCP Stream."

**Success:** you can tell "dropped" from "rejected" from "nothing listening" just by looking at packets.

### Lab 8: Routing and a Linux router (40 min, needs 2–3 VMs)

Setup: VM R has two interfaces (net1: `10.1.0.1/24`, net2: `10.2.0.1/24`). VM A on net1 (`10.1.0.10`), VM B on net2 (`10.2.0.10`).

1. On A: set default route via `10.1.0.1`. On B: default via `10.2.0.1`.
2. `ping` from A to B fails. On R: `sysctl -w net.ipv4.ip_forward=1`. Ping works.
3. Make forwarding persistent in `/etc/sysctl.d/`.
4. On R, add a firewall FORWARD policy of drop, then allow only A→B on TCP 22. Test.
5. If R also has internet access via a third interface, add masquerade (firewalld `--add-masquerade` / nft `masquerade` / iptables `MASQUERADE`) and let A reach the internet.
6. `traceroute` from A to B and see R as a hop.

**Success:** you built a router with a firewall and NAT.

### Lab 9: VLAN, bridge, and bond (30 min, virtual is fine)

1. Create VLAN 100 on your interface with `ip link add ... type vlan id 100`, give it an address, `ip -d link show`. Delete it. Recreate it with your manager persistently.
2. Create a bridge `br0` with your manager, move your interface's IP to the bridge. (Do this from the VM console, not SSH!) Verify with `bridge link`.
3. If your VM has two NICs, create an `active-backup` bond. Check `/proc/net/bonding/bond0`. Disconnect one NIC in the hypervisor and watch the active slave change while a `ping` keeps running.

**Success:** you understand where the IP lives in each virtual topology.

### Lab 10: Namespaces and SSH tunnels (20 min)

1. Do the namespace example in Section 16.4. Run `ip netns exec test ss -tulnp` and see it's empty.
2. Run `python3 -m http.server 8000` inside the namespace and reach it from the host via the veth address.
3. From your laptop: `ssh -L 8080:127.0.0.1:8000 user@A` and open `http://localhost:8080`. Explain the path the traffic takes.
4. Set up `~/.ssh/config` with a `Host` entry and an ed25519 key; confirm password-free login.

**Success:** you can reach isolated services via tunnels.

### Lab 11: Break/fix challenge (do with a friend or script it)

Have someone secretly do ONE of these on a VM; you diagnose it using only the ladder in Section 23:

- Change the gateway to a wrong IP
- Set the nameserver to an unreachable IP
- Add a DROP rule for port 22 from a specific source
- Set `rp_filter` and add an asymmetric route
- Set the MTU to 600
- Bind sshd to 127.0.0.1 only
- Remove the `/24` so the address becomes `/32`
- Put the interface in the wrong VLAN
- Enable a second manager for the same interface
- Add a bogus `/etc/hosts` entry for a common site

**Success:** every one found and fixed in under 10 minutes.

---

## 25. Quiz

Answer without looking, then check Section 26.

**Part A: Multiple choice**

1. Which command shows all IP addresses on all interfaces on a modern Linux system?
   a) `ifconfig` b) `ip addr` c) `netstat -i` d) `route -n`

2. What does `LOWER_UP` mean in `ip link` output?
   a) The interface is administratively enabled b) A cable/link is detected c) The MTU is below 1500 d) IPv6 is disabled

3. Which file controls the *order* in which Linux looks up hostnames?
   a) `/etc/hosts` b) `/etc/resolv.conf` c) `/etc/nsswitch.conf` d) `/etc/hostname`

4. Your `/etc/resolv.conf` says `nameserver 127.0.0.53`. What does that mean?
   a) DNS is broken b) systemd-resolved is the local stub resolver c) The machine is its own authoritative DNS server d) Nothing is configured

5. Which `ss` command shows listening TCP and UDP ports with process names, using numbers instead of names?
   a) `ss -a` b) `ss -tulnp` c) `ss -rn` d) `ss -x`

6. In firewalld you ran `firewall-cmd --add-port=8080/tcp --permanent` but clients still can't connect. Most likely you forgot:
   a) `--zone=public` b) `--reload` c) `--runtime-to-permanent` d) `systemctl restart NetworkManager`

7. A service is reachable from the server itself but not from other machines. `ss -tlnp` shows `127.0.0.1:5432`. The fix is:
   a) Open the firewall b) Make the service listen on `0.0.0.0` or the LAN IP c) Add a route d) Restart NetworkManager

8. Which tool combines traceroute and ping and updates continuously?
   a) `tracepath` b) `mtr` c) `nmap` d) `arping`

9. Which netplan key is deprecated in favor of a `routes:` entry?
   a) `dhcp4` b) `gateway4` c) `nameservers` d) `mtu`

10. `ip addr add 10.0.0.5 dev eth0` (no prefix) results in:
    a) A /24 address b) A /8 address c) A /32 address d) An error

11. Which mode of bonding requires the switch to be configured for LACP?
    a) active-backup b) balance-rr c) 802.3ad d) balance-tlb

12. `dig` resolves a name but your application cannot. What should you test next?
    a) `ping` b) `getent hosts NAME` c) `traceroute` d) `ethtool`

13. Small pings work over your VPN but SSH sessions freeze once you run a big command. Suspect:
    a) DNS b) Duplex mismatch c) MTU / fragmentation d) SELinux

14. Which command lets Linux forward packets between interfaces?
    a) `sysctl -w net.ipv4.ip_forward=1` b) `ip route add forward` c) `nft add forward` d) `ip link set forwarding on`

15. Which command shows the complete kernel firewall, regardless of whether firewalld, ufw, or Docker created the rules?
    a) `iptables -L` b) `ufw status` c) `nft list ruleset` d) `firewall-cmd --list-all`

16. In RHEL 10, the `ifcfg-*` files in `/etc/sysconfig/network-scripts/` are:
    a) The default b) Deprecated but working c) Removed d) Only for IPv6

17. On Debian, which package name provides `dig`?
    a) `bind` b) `bind-utils` c) `bind9-dnsutils` d) `dig`

18. Which tcpdump flag means a TCP connection was refused/reset?
    a) `[S]` b) `[S.]` c) `[R]` d) `[P.]`

19. What is the safest way to apply a new netplan config over SSH?
    a) `netplan apply` b) `netplan try` c) `reboot` d) `systemctl restart networking`

20. Which ICMPv6 rule is a mistake in an IPv6 firewall?
    a) Allow echo-request b) Allow packet-too-big c) Drop all ICMPv6 d) Allow neighbor solicitation

**Part B: Short answer**

21. Give the `ip` equivalents of `ifconfig`, `route -n`, `arp -n`, and `netstat -tulnp`.
22. Write the `nmcli` command to set `ens192` to static IP `172.16.5.20/22`, gateway `172.16.4.1`, DNS `172.16.4.53`.
23. What subnet mask does `/22` equal, and how many usable hosts does it have?
24. Explain the difference between DROP and REJECT.
25. Name the three hostname kinds `hostnamectl` manages.
26. What does `ip route get 8.8.8.8` tell you that `ip route` doesn't?
27. Your interface was `ens192` on the old VM but the cloned VM has no network. What's the likely cause and first command to run?
28. List the four steps of a DHCP lease (the "DORA" acronym) and the tcpdump filter to watch them.
29. Write an nftables rule to accept TCP ports 80 and 443 in one line.
30. Why should you run `tmux` before changing a remote server's network config?

**Part C: Scenario**

31. A web server on Ubuntu 24.04 can `ping 1.1.1.1` but `curl https://example.com` fails with "Could not resolve host." Describe, in order, the five commands you'd run and what each tells you.

32. On a Rocky Linux 9 host, `nginx` is running (`systemctl status nginx` = active), `ss -tlnp` shows `*:80`, but `curl http://SERVER_IP` from another machine times out. `ping` works. List the two most likely causes and the exact command to check each.

33. Users report a database server "randomly disconnects every few minutes." `ip neigh` on a client shows the server's IP alternating between two MAC addresses. What's wrong and how do you confirm it?

---

## 26. Quiz Answers

1. **b.** `ip addr` (or `ip -br addr`). `ifconfig` is legacy and may hide extra addresses.
2. **b.** `UP` = admin enabled; `LOWER_UP` = physical link detected. `NO-CARRIER` = no link.
3. **c.** `/etc/nsswitch.conf` (the `hosts:` line).
4. **b.** systemd-resolved listens on 127.0.0.53; see real servers with `resolvectl status`.
5. **b.** `ss -tulnp`.
6. **b.** `--permanent` writes to disk but doesn't touch the running firewall until `--reload`.
7. **b.** Bound to loopback only; change the service's listen/bind address (e.g. `listen_addresses = '*'` in PostgreSQL), then also check the firewall.
8. **b.** `mtr`.
9. **b.** `gateway4` (and `gateway6`). Use `routes: - to: default via: X`.
10. **c.** `/32`.
11. **c.** 802.3ad (LACP). `active-backup` needs nothing on the switch.
12. **b.** `getent hosts` uses nsswitch and `/etc/hosts` like real apps; `dig` goes straight to DNS.
13. **c.** MTU. Test with `ping -M do -s 1472 host` and lower until it passes.
14. **a.** And persist in `/etc/sysctl.d/`.
15. **c.** `nft list ruleset` shows the real kernel rules.
16. **c.** Removed in RHEL 10 (deprecated in 9). Use NetworkManager keyfiles / `nmcli`.
17. **c.** `bind9-dnsutils` (older: `dnsutils`). RHEL: `bind-utils`.
18. **c.** `[R]` = RST. `[S]` SYN, `[S.]` SYN-ACK, `[P.]` PSH-ACK (data).
19. **b.** `netplan try` rolls back automatically if you lose the connection.
20. **c.** IPv6 needs ICMPv6 for neighbor discovery and path MTU; never drop it all.

21. `ifconfig` → `ip addr` (and `ip link`); `route -n` → `ip route`; `arp -n` → `ip neigh`; `netstat -tulnp` → `ss -tulnp`.
22. `sudo nmcli connection modify ens192 ipv4.method manual ipv4.addresses 172.16.5.20/22 ipv4.gateway 172.16.4.1 ipv4.dns 172.16.4.53 && sudo nmcli connection up ens192`
23. `255.255.252.0`; 1024 addresses, 1022 usable (minus network and broadcast).
24. DROP silently discards the packet (client waits until timeout). REJECT discards but sends back an ICMP unreachable or TCP RST so the client fails immediately. DROP hides you from scanners; REJECT is friendlier internally.
25. Static (`/etc/hostname`), transient (runtime/DHCP), pretty (human-friendly).
26. Which specific interface, gateway, and *source address* the kernel would use for that one destination, after evaluating all routes, metrics, and policy rules.
27. The interface got a new predictable name (different virtual PCI slot). Run `ip link` (or `nmcli device`) to see the real name, then fix the config to match.
28. Discover, Offer, Request, Acknowledge. `sudo tcpdump -ni IFACE -vvv port 67 or port 68`.
29. `nft add rule inet filter input tcp dport { 80, 443 } accept`
30. If the change cuts your SSH session, commands in a `tmux` session keep running (e.g. a rollback timer) and you can reattach from the console; also long `nmcli`/`netplan` operations won't be killed mid-way by a dropped connection.

31. Example answer:
    1. `resolvectl status` → which DNS servers are configured per interface (Ubuntu uses systemd-resolved).
    2. `dig example.com` → does DNS itself answer? Check `SERVER:` and `status:`.
    3. `dig @1.1.1.1 example.com` → if this works, the configured server is the problem, not the network.
    4. `getent hosts example.com` and `cat /etc/nsswitch.conf` → what the app really sees.
    5. `cat /etc/netplan/*.yaml` / `ls -l /etc/resolv.conf` → fix the DNS at the source (netplan `nameservers:` then `netplan try`), or `resolvectl flush-caches`.
    (Also check for a stray `/etc/hosts` entry or a proxy variable with `env | grep -i proxy`.)

32. (a) **firewalld** not allowing http: `sudo firewall-cmd --list-all` (fix: `--add-service=http --permanent && --reload`). (b) **SELinux** if nginx serves from a non-standard directory or port (the listening part works, but access can be denied; for port issues): `sudo ausearch -m avc -ts recent` / `getenforce`. Also consider a cloud security group. Confirm with `sudo tcpdump -ni IFACE port 80` on the server: SYNs arriving with no SYN-ACK points at the firewall.

33. A **duplicate IP address**: two machines claim the server's IP, so ARP replies flip between MACs. Confirm with `arping -D -I IFACE SERVER_IP` (duplicate detection) or `sudo tcpdump -ni IFACE arp and host SERVER_IP` and watch replies from two MACs. Find the second MAC on the switch and fix that host's config or DHCP reservation.

---

## 27. One-Page Command Cheat Sheet

```
# LOOK
ip -br -c link / addr              interfaces, state, IPs
ip route ; ip route get X          routes ; which path to X
ip neigh                           ARP/NDP table
ss -tulnp                          listening ports + programs
ss -tnp                            established TCP
ethtool IFACE ; ethtool -S IFACE   link speed/duplex ; NIC error counters
ip -s link                         packet/error counters
hostnamectl ; resolvectl status    name ; DNS servers
nmcli device ; nmcli con show      NetworkManager state
networkctl status                  systemd-networkd state
nft list ruleset                   the real firewall
firewall-cmd --list-all ; ufw status verbose

# TEMPORARY CHANGE (gone at reboot)
ip addr add A/PREFIX dev IFACE ; ip addr del ...
ip link set IFACE up|down ; ip link set IFACE mtu N
ip route add NET via GW ; ip route replace default via GW
ip link add link IFACE name IFACE.ID type vlan id ID

# PERSISTENT CHANGE
nmcli con mod NAME ipv4.method manual ipv4.addresses A/P ipv4.gateway G ipv4.dns "D1 D2" ; nmcli con up NAME
nmtui
/etc/netplan/*.yaml ; netplan try ; netplan apply
/etc/systemd/network/*.network ; networkctl reload
/etc/network/interfaces ; ifdown X ; ifup X
hostnamectl set-hostname NAME
/etc/sysctl.d/*.conf ; sysctl --system

# TEST
ping -c3 X ; ping -M do -s 1472 X          reach ; MTU test
traceroute -n X ; tracepath X ; mtr -rwc 50 X
dig NAME ; dig +short ; dig -x IP ; dig @SERVER NAME ; dig +trace NAME
getent hosts NAME                          what apps see
nc -zv HOST PORT ; nc -l PORT              port open? ; fake listener
curl -v URL ; curl -I URL ; curl --resolve
arping -I IFACE IP ; arping -D -I IFACE IP  ARP ; duplicate check
iperf3 -s / iperf3 -c HOST                 bandwidth
nmap -sn NET/24 ; nmap -p- HOST            hosts alive ; ports

# CAPTURE
tcpdump -ni IFACE host X and port Y
tcpdump -ni IFACE -w f.pcap -c 200 ; tcpdump -nr f.pcap
tshark -r f.pcap -Y "dns"

# FIREWALL
firewall-cmd --add-service=http --permanent && firewall-cmd --reload
ufw allow 80/tcp ; ufw enable
nft add rule inet filter input tcp dport 80 accept
iptables -A INPUT -p tcp --dport 80 -j ACCEPT ; iptables-save

# LOGS
journalctl -u NetworkManager|systemd-networkd|sshd -f ; journalctl -k ; dmesg -T

# LEGACY (know for exams / old boxes)
ifconfig ; route -n ; arp -n ; netstat -tulnp ; iwconfig ; brctl show ; vconfig
```

---

*End of tutorial. Keep this file nearby, practice the labs twice, and take the quiz until you score 100%. Good luck on your certification!*
