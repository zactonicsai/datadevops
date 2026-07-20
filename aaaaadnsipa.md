# The Complete FreeIPA Guide

**Everything about IPA on Linux: how it works, how to set it up, why it breaks, and how to fix it automatically**

*Written in plain language. Last updated July 2026. Current stable version: FreeIPA 4.13.2.*

---

## Table of Contents

1. [Start Here: What Is IPA, Really?](#1-start-here-what-is-ipa-really)
2. [Quick Win: Build a Working IPA Server in 30 Minutes](#2-quick-win-build-a-working-ipa-server-in-30-minutes)
3. [The Deep Background: How IPA Actually Works Inside](#3-the-deep-background-how-ipa-actually-works-inside)
4. [**Deep Dive: The `named` Service and DNS Resolution**](#4-deep-dive-the-named-service-and-dns-resolution) ⭐
5. [Checking Status: Every Verification Command You Need](#5-checking-status-every-verification-command-you-need)
6. [The Big List: 25 Ways IPA Fails and How to Fix Each One](#6-the-big-list-25-ways-ipa-fails-and-how-to-fix-each-one)
7. [Automating Recovery: Scripts That Fix Things While You Sleep](#7-automating-recovery-scripts-that-fix-things-while-you-sleep)
8. [Monitoring: Knowing Before Your Users Do](#8-monitoring-knowing-before-your-users-do)
9. [Backup and Disaster Recovery](#9-backup-and-disaster-recovery)
10. [Alternatives: Is Something Else More Reliable?](#10-alternatives-is-something-else-more-reliable)
11. [Best Practices Checklist](#11-best-practices-checklist)
12. [Command Cheat Sheet](#12-command-cheat-sheet)
13. [Glossary](#13-glossary)

---

## 1. Start Here: What Is IPA, Really?

### The one-sentence answer

FreeIPA is a program that lets you keep all your usernames, passwords, and access rules in **one place** instead of on every single computer.

### The problem it solves

Imagine your school has 200 computers. Without something like IPA, every student account has to be created separately on every machine. If a student changes their password, someone has to change it 200 times. If a student graduates, someone has to delete them 200 times. And if they forget one machine, that student can still log in forever.

That's a nightmare. IPA fixes it.

With IPA, there's **one server** that holds all the accounts. Every other computer asks that server: "Is this person real? Should I let them in?" Change a password once, and it's changed everywhere instantly.

### What the letters mean

| Letter | Stands for | What it does |
|---|---|---|
| **I** | Identity | Knows *who* you are (users, groups, computers) |
| **P** | Policy | Knows *what you're allowed to do* (which machines you can log into, what commands you can run as admin) |
| **A** | Audit | Keeps *records* of what happened (who logged in, when, and from where) |

### The family tree

There are two names for basically the same thing, and people mix them up constantly:

- **FreeIPA** — the free, open-source version. Anyone can download it. New features land here first.
- **Red Hat Identity Management (IdM)** — the paid, supported version that ships inside Red Hat Enterprise Linux. It's FreeIPA, but tested harder and backed by a support contract.

Think of it like a car company: FreeIPA is the concept car where new ideas get tested. IdM is the model that actually goes on sale with a warranty.

> **Important note for 2026:** Red Hat only supports IdM when it runs on RHEL. If you install FreeIPA on Ubuntu or Debian, you're on your own — community support only.

### The Active Directory comparison

If you know Windows, this is the shortcut: **IPA is Linux's answer to Active Directory.**

| Feature | Active Directory | FreeIPA |
|---|---|---|
| Stores users and groups | ✅ | ✅ |
| Single sign-on with Kerberos | ✅ | ✅ |
| Group policy / access rules | ✅ Group Policy Objects | ✅ HBAC rules |
| Built-in certificate authority | ✅ AD CS (separate role) | ✅ Dogtag (built in) |
| Manages Windows machines | ✅ Excellent | ❌ No |
| Manages Linux machines | ⚠️ Works, but clunky | ✅ Excellent |
| Cost | Windows Server licenses | Free |

They can also **shake hands** with each other. This is called a *cross-forest trust*. Your Windows users can log into Linux machines without having two separate accounts. That's usually the smartest setup for mixed environments.

---

## 2. Quick Win: Build a Working IPA Server in 30 Minutes

We're going to build a real, working IPA server before explaining all the theory. Learning by doing sticks better.

### What you need before starting

| Requirement | Minimum | Recommended | Why it matters |
|---|---|---|---|
| Operating system | RHEL 9/10, Rocky 9/10, AlmaLinux 9/10, Fedora 42+ | RHEL 10 | Best-tested platforms |
| RAM | 4 GB | 8 GB | The database and Java CA are hungry |
| Disk | 20 GB | 50 GB+ on `/var` | Logs and the database grow over time |
| CPU | 2 cores | 4 cores | Certificate operations are CPU-heavy |
| Network | **Static IP address** | Static IP | A moving IP breaks everything |
| Hostname | Fully qualified (FQDN) | `ipa1.lab.example.com` | Kerberos requires this |

> ⚠️ **The #1 rookie mistake:** using a hostname without a domain, like just `ipa1`. Kerberos will refuse to work. It **must** be `something.something.something`.

### Step 1: Set the hostname correctly

```bash
sudo hostnamectl set-hostname ipa1.lab.example.com
hostname -f
```

The second command must print the full name back. If it prints something short, stop and fix it before continuing.

### Step 2: Make the machine able to find itself

Edit `/etc/hosts`:

```bash
sudo vi /etc/hosts
```

Add a line with your real IP address:

```
192.168.10.10   ipa1.lab.example.com   ipa1
```

Test it both directions:

```bash
ping -c1 ipa1.lab.example.com     # name → IP works?
getent hosts 192.168.10.10        # IP → name works?
```

Both must succeed. This is called forward and reverse resolution, and IPA checks both during install.

### Step 3: Get the clock right

Kerberos is extremely picky about time. If two machines disagree by more than **5 minutes**, logins fail with confusing errors.

```bash
sudo dnf install -y chrony
sudo systemctl enable --now chronyd
chronyc tracking
```

Look for `Leap status : Normal` and a small `System time` offset. If it says "Not synchronised," wait a minute and check again.

### Step 4: Open the firewall

IPA needs a lot of doors open. Here they all are at once:

```bash
sudo firewall-cmd --permanent --add-service={freeipa-4,dns,ntp}
sudo firewall-cmd --reload
sudo firewall-cmd --list-all
```

On older systems where `freeipa-4` doesn't exist, open ports manually:

```bash
sudo firewall-cmd --permanent \
  --add-port={80/tcp,443/tcp,389/tcp,636/tcp,88/tcp,88/udp,464/tcp,464/udp,53/tcp,53/udp,123/udp}
sudo firewall-cmd --reload
```

### Step 5: Install the packages

```bash
# RHEL / Rocky / Alma 9 and 10
sudo dnf module enable idm:DL1 -y     # RHEL 9 only; skip on RHEL 10
sudo dnf install -y ipa-server ipa-server-dns

# Fedora
sudo dnf install -y freeipa-server freeipa-server-dns
```

### Step 6: Run the installer

This is the big moment. Read every prompt carefully.

```bash
sudo ipa-server-install \
  --domain=lab.example.com \
  --realm=LAB.EXAMPLE.COM \
  --hostname=ipa1.lab.example.com \
  --setup-dns \
  --auto-forwarders \
  --no-ntp
```

**Decoding the options:**

| Option | Plain English |
|---|---|
| `--domain` | Your DNS domain, lowercase |
| `--realm` | Your Kerberos realm — **always the domain in CAPITAL LETTERS** |
| `--hostname` | This server's full name |
| `--setup-dns` | Let IPA run DNS for you (strongly recommended) |
| `--auto-forwarders` | Send unknown lookups to whatever DNS the machine already uses |
| `--no-ntp` | You already set up chrony in Step 3 |

The installer will ask you for two passwords:

1. **Directory Manager password** — the master key to the raw database. Write it down somewhere very safe. You will need it for backups and disaster recovery.
2. **IPA admin password** — the everyday administrator account.

Both should be at least 12 characters. The installer takes **10–20 minutes**. Don't interrupt it.

### Step 7: Verify it actually worked

```bash
# Are all services running?
sudo ipactl status

# Can you get a Kerberos ticket?
kinit admin
klist

# Can you talk to the API?
ipa user-find admin
```

Good output from `ipactl status` looks like this:

```
Directory Service: RUNNING
krb5kdc Service: RUNNING
kadmin Service: RUNNING
named Service: RUNNING
httpd Service: RUNNING
ipa-custodia Service: RUNNING
pki-tomcatd Service: RUNNING
ipa-otpd Service: RUNNING
ipa-dnskeysyncd Service: RUNNING
ipa: INFO: The ipactl command was successful
```

If every line says RUNNING, congratulations — you have a working IPA server.

### Step 8: Log into the web interface

Open a browser and go to:

```
https://ipa1.lab.example.com
```

You'll get a certificate warning the first time because the certificate was signed by your own new CA, not a public one. That's expected. Accept it and log in as `admin`.

### Step 9: Create your first user

```bash
kinit admin
ipa user-add jsmith --first=Jane --last=Smith --password
ipa group-add developers --desc="Development team"
ipa group-add-member developers --users=jsmith
ipa user-show jsmith
```

### Step 10: Enroll a client machine

On a *different* Linux machine:

```bash
sudo dnf install -y ipa-client
sudo ipa-client-install \
  --mkhomedir \
  --enable-dns-updates \
  --principal admin
```

The `--mkhomedir` flag automatically creates a home folder the first time someone logs in. Without it, users log in and land in a directory that doesn't exist — a very common complaint.

Test it:

```bash
id jsmith
su - jsmith
```

**You now have a working centralized identity system.** Everything below explains what just happened and how to keep it alive.

---

## 3. The Deep Background: How IPA Actually Works Inside

### The stack, top to bottom

IPA isn't one program. It's about eight programs wearing a trench coat, pretending to be one thing. Here's what's inside:

```
┌─────────────────────────────────────────────────────┐
│  Web UI (browser)          CLI (ipa command)        │
└──────────────────┬──────────────────────────────────┘
                   │  XML-RPC / JSON-RPC over HTTPS
┌──────────────────▼──────────────────────────────────┐
│  Apache httpd + mod_wsgi  ← the IPA API framework   │
└──────────────────┬──────────────────────────────────┘
                   │  LDAP
┌──────────────────▼──────────────────────────────────┐
│  389 Directory Server  ← THE DATABASE (everything)  │
│  ├─ ipa-pwd-extop     (password plugin)             │
│  ├─ ipa-lockout       (failed login tracking)       │
│  ├─ ipa-sidgen        (Windows SID generation)      │
│  ├─ ipa-extdom        (AD trust lookups)            │
│  └─ topology plugin   (replication management)      │
└───┬────────┬─────────┬──────────┬───────────────────┘
    │        │         │          │
┌───▼───┐ ┌──▼────┐ ┌──▼──────┐ ┌─▼──────────┐
│krb5kdc│ │Dogtag │ │  BIND   │ │ipa-custodia│
│Kerberos│ │  CA   │ │  DNS    │ │  secrets   │
└───────┘ └───────┘ └─────────┘ └────────────┘
```

### The nine services, explained one by one

#### 1. **389 Directory Server** (`dirsrv`) — the heart

This is an LDAP database. Everything lives here: users, groups, hosts, policies, even the Kerberos keys and DNS records.

**Key insight:** if 389-ds is down, *everything* is down. It's the foundation. Every other service reads from it.

The database files live in `/var/lib/dirsrv/slapd-YOUR-REALM/`.

In RHEL 10 and newer, 389-ds uses a database engine called **LMDB** instead of the older Berkeley DB. LMDB is faster and handles crashes better, but it needs its map size configured properly or it fills up.

#### 2. **krb5kdc** — the ticket booth

Kerberos is the authentication system. Here's the idea in plain language:

Instead of sending your password to every service you use, you prove your identity **once** to the KDC (Key Distribution Center). It gives you a **ticket** — like a wristband at a theme park. You show that wristband to every ride, and nobody needs to see your ID again.

The flow:

```
1. You run: kinit jsmith
2. Your computer asks the KDC: "Prove I'm Jane"
3. KDC replies with a Ticket Granting Ticket (TGT), encrypted with your password
4. Your computer decrypts it → proof you knew the password
5. Now you want to SSH somewhere. Your computer shows the TGT to the KDC
6. KDC hands back a service ticket for that specific SSH server
7. SSH server checks the ticket. You're in. No password ever crossed the network.
```

Tickets expire — usually after 24 hours. Then you `kinit` again.

**Why the clock matters so much:** tickets contain timestamps. If your clock is more than 5 minutes off from the KDC's clock, the KDC assumes it's a replay attack and rejects you. This causes more IPA support tickets than any other single issue.

#### 3. **kadmin** — the ticket booth's admin office

Handles password changes and principal (account) management for Kerberos. Less visible, but breaks things when it's down.

#### 4. **Dogtag PKI** (`pki-tomcatd`) — the certificate factory

This is a full certificate authority written in Java, running inside Tomcat. It issues the TLS certificates for your web server, LDAP, and any host or service that asks for one.

**Why it matters:** IPA's own internal services authenticate to each other using certificates issued by Dogtag. When those certificates expire, IPA breaks in dramatic and confusing ways.

Modern IPA (RHEL 10+) enables **random serial numbers v3 (RSNv3)** by default, plus automatic pruning of expired certificates 30 days after they expire. This is a meaningful improvement — the old sequential serial numbers made certain attacks easier and the database grew forever.

#### 5. **BIND with the IPA plugin** (`named`) — the phone book

DNS. Optional, but strongly recommended. IPA uses special DNS records called **SRV records** so clients can *automatically discover* where the KDC and LDAP servers are, without hardcoding anything.

If you look at your DNS zone you'll find entries like:

```
_kerberos._tcp.lab.example.com.  SRV  0 100 88 ipa1.lab.example.com.
_ldap._tcp.lab.example.com.      SRV  0 100 389 ipa1.lab.example.com.
```

That's the magic behind `ipa-client-install` finding your server with no configuration.

#### 6. **ipa-custodia** — the secret courier

When you add a new replica server, it needs copies of sensitive keys. Custodia securely transfers those secrets between servers. You rarely think about it — until it fails and replica installation dies halfway through.

#### 7. **ipa-otpd** — the two-factor helper

Handles one-time passwords (the six-digit codes from an app) and RADIUS forwarding. Also handles passkeys in newer versions.

#### 8. **ipa-dnskeysyncd** — the DNSSEC key manager

Synchronizes DNSSEC signing keys between the LDAP database and BIND. This one has a history of breaking during major version upgrades — it was specifically fixed in FreeIPA 4.13.1 for RHEL 9.4→9.6 upgrades.

#### 9. **SSSD** — the client-side brain

This one runs on **clients**, not the server. SSSD (System Security Services Daemon) is what actually talks to IPA when a user tries to log in.

Its most valuable feature is the **cache**. SSSD remembers recent logins, so if the IPA server goes down temporarily, users who logged in recently can still get in. This is called *offline authentication*, and it's your safety net.

Its config lives at `/etc/sssd/sssd.conf` and its cache at `/var/lib/sss/db/`.

### How data flows when someone logs in

Let's trace a real SSH login, step by step:

```
Jane types: ssh jsmith@webserver.lab.example.com

1. SSH daemon on webserver asks PAM: "is jsmith allowed?"
2. PAM asks SSSD
3. SSSD checks its local cache first
   → cache hit and fresh? Answer immediately.
   → cache miss or stale? Continue...
4. SSSD looks up DNS SRV records to find an IPA server
5. SSSD connects to 389-ds via LDAP over TLS (port 636)
6. SSSD asks: "does jsmith exist? what's her UID, home dir, shell?"
7. SSSD authenticates the password against krb5kdc (port 88)
8. SSSD checks HBAC rules: "is jsmith allowed on THIS host?"
9. If yes → SSSD tells PAM "approved"
10. PAM creates the home directory (if --mkhomedir was used)
11. Jane gets a shell
```

**Every single one of those steps is a potential failure point.** That's why the failure list in the next section is so long.

### Replication: how multiple servers stay in sync

You should never run just one IPA server in production. Two or more servers replicate to each other.

- Replication is **multi-master** — you can write changes to any server, and they propagate to the others.
- It uses **CSNs** (Change Sequence Numbers) to decide which change wins when two servers are edited at the same time. Newest timestamp wins.
- The **topology plugin** manages which servers talk to which. You want a mesh or ring, not a star with a single point of failure.

**The dark side:** when replication breaks, the servers drift apart silently. One server says Jane's password is X, another says it's Y. Users get random login failures depending on which server they hit. This is the single hardest class of IPA problem to diagnose.

### The certificate expiry time bomb

This deserves its own section because it destroys more IPA installations than anything else.

IPA generates a set of internal certificates during install:

| Certificate | Default lifetime | What breaks when it expires |
|---|---|---|
| IPA CA certificate | 20 years | Absolutely everything |
| Subsystem certificates (Dogtag internal) | 2 years | CA stops issuing certs; upgrades fail |
| HTTP/LDAP server certs | 2 years | Web UI and LDAP TLS fail |
| IPA RA agent cert | 2 years | Certificate requests fail |

`certmonger` is supposed to renew these automatically. It usually does. But if certmonger was stopped, or the server was powered off past the renewal window, or a previous renewal partly failed, the certificates expire — and then you're in a genuinely painful recovery situation, because the tools you'd use to fix it also need working certificates.

**Check your expiry dates today. Seriously.**

```bash
sudo getcert list | grep -E 'expires|status|Request ID'
```

---

## 4. Deep Dive: The `named` Service and DNS Resolution

> **Read this section even if you skip others.** DNS is the failure surface that causes the most confusing outages in FreeIPA, because when DNS breaks, *every other component reports a different symptom* and none of them mention DNS.

### Why DNS deserves its own section

Kerberos, LDAP, certificate validation, replication, and client enrollment **all** depend on name resolution. When DNS breaks, you don't get "DNS is broken." You get:

- `kinit: Cannot find KDC for realm` — looks like Kerberos
- `ipa: ERROR: cannot connect to 'ldap://...'` — looks like LDAP
- `Certificate hostname mismatch` — looks like PKI
- `ipa-client-install: Domain not found` — looks like enrollment
- Replication silently stops — looks like the topology plugin

Every one of those is DNS. **Check DNS first, always.** It costs 30 seconds and eliminates the most common root cause.

### What `named` actually is in FreeIPA

FreeIPA doesn't run stock BIND. It runs BIND with a plugin called **`bind-dyndb-ldap`**, which makes BIND read its zone data directly out of the 389-ds LDAP database instead of from flat zone files.

```
         ┌──────────────────────────────┐
         │   named (BIND 9)             │
         │   ┌────────────────────────┐ │
         │   │  bind-dyndb-ldap       │ │  ← the plugin
         │   └───────────┬────────────┘ │
         └───────────────┼──────────────┘
                         │ LDAP (GSSAPI over ldapi:// socket)
                         ▼
         ┌──────────────────────────────┐
         │  389-ds: cn=dns,dc=example…  │
         │  idnsZone / idnsRecord objs  │
         └──────────────────────────────┘
```

**Three consequences follow from this design, and they explain most DNS failures:**

1. **If LDAP is slow or down, DNS breaks.** The plugin has an LDAP query timeout; if the LDAP server doesn't respond before it expires, the lookup is aborted and **BIND returns SERVFAIL**. A `0` value means infinite timeout.

2. **DNS records replicate through LDAP replication**, not through DNS zone transfers. Your DNS topology *is* your IPA replication topology.

3. **`bind-dyndb-ldap` does not support outbound zone transfers.** You cannot make a stock BIND server a secondary of a FreeIPA DNS server. If you need external secondaries, you need a different approach entirely.

### The DNS records that make FreeIPA work

FreeIPA relies on **SRV records** for service discovery. This is how a client with zero configuration finds your KDC.

```bash
# The critical records — memorize these four
dig +short -t SRV _kerberos._tcp.example.com     # KDC location
dig +short -t SRV _ldap._tcp.example.com         # LDAP location
dig +short -t SRV _kerberos-master._tcp.example.com
dig +short -t SRV _kpasswd._tcp.example.com      # password changes

# TXT record holds the Kerberos realm name
dig +short -t TXT _kerberos.example.com

# URI records (newer deployments)
dig +short -t URI _kerberos.example.com
```

Healthy output looks like:

```
0 100 88 ipa1.example.com.
0 100 88 ipa2.example.com.
```

That's `priority weight port target`. Two entries = two KDCs available = failover works.

**If these are missing or wrong, nothing works.** Regenerate them:

```bash
kinit admin
ipa dns-update-system-records --dry-run   # preview first, always
ipa dns-update-system-records
```

### The 90-second DNS health check

Run this whenever anything IPA-related misbehaves. It has caught more root causes than any other single diagnostic.

```bash
#!/usr/bin/env bash
# ipa-dns-check.sh — run on any IPA server or client
DOMAIN="${1:-example.com}"
HOST=$(hostname -f)

echo "=== 1. Am I who I think I am? ==="
hostname -f
getent hosts "$HOST"

echo "=== 2. Forward resolution ==="
dig +short "$HOST"

echo "=== 3. Reverse resolution (often the broken one) ==="
IP=$(dig +short "$HOST" | head -1)
dig +short -x "$IP"

echo "=== 4. Critical SRV records ==="
for rec in _kerberos._tcp _ldap._tcp _kpasswd._tcp; do
  printf '%-22s ' "$rec"
  dig +short -t SRV "${rec}.${DOMAIN}" | tr '\n' ' '
  echo
done

echo "=== 5. Realm TXT record ==="
dig +short -t TXT "_kerberos.${DOMAIN}"

echo "=== 6. Which resolver am I actually using? ==="
cat /etc/resolv.conf | grep -v '^#'

echo "=== 7. Is named answering locally? ==="
dig +short @127.0.0.1 "$HOST"

echo "=== 8. Can I resolve the outside world? (forwarders) ==="
dig +short @127.0.0.1 www.google.com

echo "=== 9. named service state ==="
systemctl is-active named 2>/dev/null || systemctl is-active named-pkcs11
```

**Interpreting the results:**

| Which step fails | What it means |
|---|---|
| 1 or 2 | Hostname/`/etc/hosts` misconfigured — fix before anything else |
| 3 only | Reverse zone missing — breaks Kerberos and PTR sync |
| 4 | SRV records gone — run `ipa dns-update-system-records` |
| 6 | Something overwrote `resolv.conf` (usually NetworkManager or DHCP) |
| 7 but not 6 | `named` is down or the LDAP backend is unreachable |
| 8 only | Forwarder problem — internal DNS fine, external broken |

### When `named` won't start

This is common enough that upstream maintains a dedicated troubleshooting guide for it. The symptom:

```
$ sudo ipactl start
Starting Directory Service
Starting KDC Service
Starting KPASSWD Service
Starting DNS Service
Job failed. See system journal and 'systemctl status' for details.
Failed to start DNS Service
Shutting down
Aborting ipactl
```

**Diagnostic sequence, in order:**

```bash
# 1. What does named itself say?
sudo journalctl -u named -n 100 --no-pager
sudo journalctl -u named-pkcs11 -n 100 --no-pager   # DNSSEC builds
sudo cat /var/named/data/named.run
sudo grep -i named /var/log/messages | tail -50

# 2. Is the config even valid?
sudo named-checkconf /etc/named.conf

# 3. Can named's identity reach the DNS subtree in LDAP?
sudo -u named kinit -k -t /etc/named.keytab \
  "DNS/$(hostname -f)@EXAMPLE.COM"
sudo -u named klist

# 4. THE key test — can it actually read DNS data from LDAP?
ldapsearch -H 'ldapi://%2fvar%2frun%2fslapd-EXAMPLE-COM.socket' \
  -Y GSSAPI -b 'cn=dns,dc=example,dc=com'
```

That last command is the one that matters. You should see objects with objectClasses **`idnsZone` and `idnsRecord`** — not just `idnsConfig`. If you only see `idnsConfig`, the zones aren't there or you can't read them.

**Most common root causes:**

| Cause | Fix |
|---|---|
| Missing/expired `/etc/named.keytab` | `ipa-getkeytab -s ipa1 -p DNS/$(hostname -f) -k /etc/named.keytab` |
| LDAP ACIs destroyed by an upgrade | Restore DNS ACIs; upstream documents this as a known upgrade casualty |
| 389-ds not running | `ipactl start` — DNS depends on it; order matters |
| SELinux denial | `ausearch -m avc -ts recent \| audit2why`, then `restorecon -Rv /etc/named*` |
| Wrong permissions on keytab | `chown named:named /etc/named.keytab && chmod 600` |

**A subtle one worth knowing:** if `named`'s Kerberos principal differs from what `/bin/hostname` returns, the plugin will authenticate as the wrong identity. The plugin exposes a `server_id`/hostname override for exactly this case, but the upstream README recommends preferring the `uri` option and only using the hostname override in special cases — such as when GSSAPI is used and named's principal doesn't match `/bin/hostname` output.

### Symptom: NXDOMAIN or forwarder answers instead of authoritative data

If queries return NXDOMAIN, or you get answers from forwarders instead of your own authoritative data, **and** dynamic updates and zone transfers are refused with `NOTAUTH` — the usual cause is that **a FreeIPA upgrade destroyed the LDAP Access Control Instructions** that granted the DNS principal access to the DNS subtree.

`named` is running. It looks healthy. It just can't read its own data, so it silently falls through to forwarders.

```bash
# Confirm: can the DNS principal read the subtree?
sudo -u named kinit -k -t /etc/named.keytab "DNS/$(hostname -f)"
ldapsearch -Y GSSAPI -b 'cn=dns,dc=example,dc=com' dn
# Permission denied or empty result → ACI problem
```

### Symptom: SERVFAIL

Work through these in order:

```bash
# 1. Is the LDAP backend responding within the timeout?
#    Plugin returns SERVFAIL when LDAP doesn't answer in time.
sudo grep -i "ldap" /var/named/data/named.run | tail -30

# 2. Are you querying a TLD you don't own? (.local, .corp, .internal)
#    DNSSEC validation will fail for these.
grep dnssec-validation /etc/named.conf

# 3. Is the forwarder itself broken?
dig +short @<forwarder-ip> www.google.com

# 4. DNSSEC key problems?
sudo journalctl -u ipa-dnskeysyncd -n 50
```

> **The `.local` trap:** using `.local`, `.corp`, or other TLDs you don't own causes DNSSEC validation failures and mDNS conflicts. Use a subdomain of a domain you actually control (`ipa.yourcompany.com`), even for internal-only deployments.

### PTR records and reverse DNS

Reverse resolution matters more in Kerberos environments than people expect. FreeIPA can synchronize PTR records automatically when A/AAAA records change.

```bash
# Create the reverse zone
ipa dnszone-add 10.0.0.0/24 --name-from-ip=10.0.0.0/24

# Enable PTR sync on the forward zone
ipa dnszone-mod example.com --allow-sync-ptr=TRUE
```

Behavior worth knowing: if an A/AAAA update succeeds but PTR synchronization fails due to misconfiguration, **SERVFAIL is no longer returned to clients** — the error is only logged. This is better behavior, but it means broken PTR sync is now silent. Check your logs periodically.

```bash
sudo grep -i "ptr" /var/named/data/named.run | tail -20
```

### Forwarders: connecting IPA DNS to the wider world

```bash
# Global forwarders (all non-authoritative queries)
ipa dnsconfig-mod --forwarder=8.8.8.8 --forwarder=1.1.1.1
ipa dnsconfig-mod --forward-policy=first    # try forwarder, fall back to recursion

# Per-zone forwarding — the pattern for AD trust and cloud VPCs
ipa dnsforwardzone-add corp.example.com \
  --forwarder=10.0.1.10 \
  --forward-policy=only

ipa dnsforwardzone-find
ipa dnsforwardzone-show corp.example.com
```

**`first` vs `only`:**

| Policy | Behavior | Use when |
|---|---|---|
| `first` | Ask forwarder, fall back to recursion if it fails | General internet resolution |
| `only` | Ask forwarder, fail if it doesn't answer | Delegating a specific internal domain (AD, VPC) |

Use `only` for AD trust zones. If you use `first` and the AD DNS server is down, IPA will try public recursion for your internal AD domain — leaking queries and returning nonsense.

### Running IPA without its own DNS

Legitimate, but you take on manual work. You must create the SRV records yourself in whatever DNS you use:

```
_kerberos._tcp.example.com.        86400 IN SRV 0 100 88  ipa1.example.com.
_kerberos._udp.example.com.        86400 IN SRV 0 100 88  ipa1.example.com.
_kerberos-master._tcp.example.com. 86400 IN SRV 0 100 88  ipa1.example.com.
_kerberos-master._udp.example.com. 86400 IN SRV 0 100 88  ipa1.example.com.
_kpasswd._tcp.example.com.         86400 IN SRV 0 100 464 ipa1.example.com.
_kpasswd._udp.example.com.         86400 IN SRV 0 100 464 ipa1.example.com.
_ldap._tcp.example.com.            86400 IN SRV 0 100 389 ipa1.example.com.
_kerberos.example.com.             86400 IN TXT "EXAMPLE.COM"
```

Repeat for every replica. Update them by hand whenever the topology changes. **This is the single most common reason "we don't need IPA DNS" turns into a months-long source of subtle breakage** — someone adds a replica and forgets the records.

```bash
# Generate the exact records you need for your topology
ipa dns-update-system-records --dry-run --out=/tmp/ipa-records.txt
cat /tmp/ipa-records.txt
```

### DNS monitoring that actually catches problems

Add to your watchdog (from Section 7):

```bash
check_dns() {
  local domain="example.com"
  local failed=0

  # SRV records must exist
  for rec in _kerberos._tcp _ldap._tcp; do
    if ! dig +short +time=3 +tries=2 -t SRV "${rec}.${domain}" | grep -q .; then
      log "DNS: missing SRV record ${rec}.${domain}"
      failed=1
    fi
  done

  # Self-resolution must work both directions
  local fqdn ip
  fqdn=$(hostname -f)
  ip=$(dig +short +time=3 "$fqdn" | head -1)
  [[ -z "$ip" ]] && { log "DNS: cannot resolve own hostname"; failed=1; }
  if [[ -n "$ip" ]] && ! dig +short -x "$ip" | grep -q "$fqdn"; then
    log "DNS: reverse lookup for $ip does not match $fqdn"
    failed=1
  fi

  # named answering locally?
  if systemctl is-active --quiet named || systemctl is-active --quiet named-pkcs11; then
    if ! dig +short +time=3 @127.0.0.1 "$fqdn" | grep -q .; then
      alert "named is running but not answering queries" \
        "$(journalctl -u named -n 40 --no-pager 2>/dev/null)
$(tail -40 /var/named/data/named.run 2>/dev/null)"
      failed=1
    fi
  fi

  # resolv.conf drift
  if ! grep -q "$(hostname -i 2>/dev/null | awk '{print $1}')\|127.0.0.1" /etc/resolv.conf 2>/dev/null; then
    log "DNS: resolv.conf may have been overwritten"
  fi

  return $failed
}
```

Prometheus metrics:

```bash
echo "# HELP ipa_dns_srv_records_present SRV records resolvable"
echo "# TYPE ipa_dns_srv_records_present gauge"
for rec in _kerberos._tcp _ldap._tcp; do
  v=$(dig +short +time=3 -t SRV "${rec}.example.com" | grep -c . || echo 0)
  echo "ipa_dns_srv_records_present{record=\"$rec\"} $v"
done

echo "# HELP ipa_dns_query_seconds Local DNS query latency"
echo "# TYPE ipa_dns_query_seconds gauge"
start=$(date +%s.%N)
dig +short +time=3 @127.0.0.1 "$(hostname -f)" >/dev/null 2>&1
end=$(date +%s.%N)
echo "ipa_dns_query_seconds $(echo "$end - $start" | bc)"
```

Alert rules:

```yaml
- alert: IPADNSSRVRecordMissing
  expr: ipa_dns_srv_records_present == 0
  for: 5m
  labels: { severity: critical }
  annotations:
    summary: "SRV record {{ $labels.record }} missing — clients cannot discover IPA"

- alert: IPADNSSlow
  expr: ipa_dns_query_seconds > 1
  for: 10m
  labels: { severity: warning }
  annotations:
    summary: "DNS queries taking {{ $value }}s — LDAP backend may be struggling"
```

### DNS golden rules

1. **Check DNS first** for any IPA problem. Thirty seconds, eliminates the top root cause.
2. **Forward and reverse must both work.** Reverse is the one people forget.
3. **Never use a TLD you don't own** — no `.local`, `.corp`, `.internal`.
4. **Pin `resolv.conf`** against NetworkManager and DHCP.
5. **`named` health ≠ `named` running.** Test with an actual query.
6. **DNS depends on LDAP.** A struggling 389-ds produces SERVFAIL.
7. **Run `dns-update-system-records` after every topology change.**
8. **No zone transfers out** of `bind-dyndb-ldap` — plan accordingly.

---

## 5. Checking Status: Every Verification Command You Need

### The 60-second health check

Run these five commands. If all five look good, IPA is probably fine.

```bash
# 1. Are all IPA services running?
sudo ipactl status

# 2. Are the underlying systemd units happy?
sudo systemctl status dirsrv@$(hostname -d | tr 'a-z.' 'A-Z-') httpd krb5kdc named pki-tomcatd

# 3. Can you authenticate?
kinit admin && klist

# 4. Can you read from the API?
ipa user-find --sizelimit=1

# 5. Are certificates healthy?
sudo getcert list | grep -c "status: MONITORING"
```

### Service-by-service verification

**LDAP (389 Directory Server)**

```bash
# Anonymous check — is it answering at all?
ldapsearch -x -H ldap://localhost -b "" -s base "(objectclass=*)" namingContexts

# Authenticated check
ldapsearch -x -D "cn=Directory Manager" -W \
  -b "dc=lab,dc=example,dc=com" "(uid=admin)" dn

# Connection count (are you running out?)
sudo ldapsearch -x -D "cn=Directory Manager" -W \
  -b "cn=monitor" -s base "(objectclass=*)" currentconnections
```

**Kerberos**

```bash
kinit admin                     # Get a ticket
klist                           # Show tickets
klist -e                        # Show encryption types used
kdestroy                        # Throw tickets away
kvno host/$(hostname)           # Can you get a service ticket?
```

**DNS**

```bash
# Do the critical SRV records exist?
dig +short -t SRV _kerberos._tcp.lab.example.com
dig +short -t SRV _ldap._tcp.lab.example.com

# Does forward resolution work?
dig +short ipa1.lab.example.com

# Does reverse work?
dig +short -x 192.168.10.10
```

**Certificates**

```bash
sudo getcert list                          # All tracked certificates
sudo ipa-cert-fix --dry-run                # Would fixing help? (RHEL 8.4+)
sudo ipa-healthcheck --source ipahealthcheck.ipa.certs
openssl x509 -in /etc/ipa/ca.crt -noout -dates   # CA validity window
```

**Replication (multi-server only)**

```bash
# List all servers in the topology
ipa server-find

# Show replication agreements
ipa topologysegment-find domain
ipa topologysegment-find ca

# The real health check
sudo ipa-replica-manage list
sudo ipa-replica-manage list -v ipa1.lab.example.com

# Look for conflict entries — these are BAD
ldapsearch -x -D "cn=Directory Manager" -W \
  -b "dc=lab,dc=example,dc=com" "(nsds5ReplConflict=*)" dn
```

### The one tool to rule them all: ipa-healthcheck

This is the most useful thing Red Hat added to IPA in the last several years. Install it if you don't have it:

```bash
sudo dnf install -y ipa-healthcheck
```

Run it:

```bash
# Everything, human-readable
sudo ipa-healthcheck --output-type human

# Only problems
sudo ipa-healthcheck --failures-only

# Just certificates
sudo ipa-healthcheck --source ipahealthcheck.ipa.certs

# Machine-readable, for monitoring systems
sudo ipa-healthcheck --output-type json --output-file /var/log/ipa-hc.json
```

What it checks: certificate expiry, replication status, DNS records, service status, file permissions, Kerberos configuration, CA setup, and about forty other things you'd never think to check manually.

**Run this weekly. Automate it. It catches problems weeks before users notice them.**

### Where the logs live

| Component | Log location | What to look for |
|---|---|---|
| IPA server API | `/var/log/httpd/error_log` | Python tracebacks, 500 errors |
| IPA install/upgrade | `/var/log/ipaserver-install.log`, `/var/log/ipaupgrade.log` | Where installs died |
| 389 Directory Server | `/var/log/dirsrv/slapd-REALM/errors` | Database corruption, replication errors |
| 389 access log | `/var/log/dirsrv/slapd-REALM/access` | Slow queries, connection floods |
| Kerberos KDC | `/var/log/krb5kdc.log` | Clock skew, unknown principals |
| Dogtag CA | `/var/log/pki/pki-tomcat/ca/debug.*` | Certificate issuance failures |
| BIND DNS | `journalctl -u named` | Zone loading failures |
| Certmonger | `journalctl -u certmonger` | Renewal attempts and failures |
| SSSD (client) | `/var/log/sssd/*.log` | Client-side auth failures |

**Turning up SSSD debugging when you're stuck:**

```bash
sudo sssctl debug-level 9
sudo systemctl restart sssd
# reproduce the problem
sudo tail -f /var/log/sssd/sssd_lab.example.com.log
sudo sssctl debug-level 0    # turn it back down, it's very noisy
```

---

## 6. The Big List: 25 Ways IPA Fails and How to Fix Each One

Failures are grouped by root cause. Each entry has: what you'll see, why it happens, how to fix it, and how to prevent it.

### 🔴 Category A: Certificate Failures (the most common cause of total outages)

---

#### Failure 1: Expired IPA subsystem certificates

**Symptoms**
- Web UI returns 500 Internal Server Error
- `ipactl status` shows `pki-tomcatd` STOPPED and it won't start
- `/var/log/httpd/error_log` contains `SSL routines... certificate expired`
- `ipa` commands fail with `cannot connect to ... SSL error`

**Why it happens**
Dogtag's internal certificates last 2 years. Certmonger renews them automatically — unless the server was off during the renewal window, certmonger was disabled, or a prior renewal half-failed. It's a slow fuse that burns for two years and then detonates.

**Diagnosis**
```bash
sudo getcert list | grep -A2 "status: CA_UNREACHABLE\|expired"
sudo openssl x509 -in /var/lib/ipa/ra-agent.pem -noout -dates
```

**Fix**
```bash
# Modern, supported way (RHEL 8.4+ / FreeIPA 4.9+)
sudo ipa-cert-fix

# It will prompt for confirmation, then reissue expired certs.
# Afterward:
sudo ipactl restart
sudo getcert list | grep status
```

If `ipa-cert-fix` can't help (CA cert itself expired), you're into manual date-rollback recovery, which is genuinely hard. This is why prevention matters so much.

**Prevention** — a cron job that warns you 60 days ahead:
```bash
#!/bin/bash
# /usr/local/sbin/ipa-cert-expiry-warn.sh
THRESHOLD=$((60*86400))
NOW=$(date +%s)
getcert list | awk '/expires:/ {print $2, $3, $4, $5}' | while read -r d; do
  EXP=$(date -d "$d" +%s 2>/dev/null) || continue
  if (( EXP - NOW < THRESHOLD )); then
    echo "IPA certificate expires soon: $d" | \
      mail -s "IPA CERT WARNING on $(hostname)" admin@example.com
  fi
done
```

---

#### Failure 2: Certmonger stopped tracking certificates

**Symptoms**
- `getcert list` shows fewer certificates than expected, or none
- Certificates quietly expire with no renewal attempt

**Why it happens**
Certmonger's tracking database (`/var/lib/certmonger/requests/`) got wiped, or a failed restore didn't bring it back, or someone ran `getcert stop-tracking` during troubleshooting and never resumed.

**Fix**
```bash
sudo ipa-certupdate
sudo systemctl restart certmonger
sudo getcert list | grep -c "status: MONITORING"
# Should be 8 or more on a CA-enabled server
```

**New in FreeIPA 4.13.1:** `ipa-certupdate` now accepts `--force-server SERVER.FQDN`, which is a lifesaver during disaster recovery when only one replica is healthy and you need everyone else to pull cert info from that specific known-good box.

---

#### Failure 3: Client certificate/CA trust mismatch

**Symptoms**
- Clients can't connect: `Peer's certificate issuer has been marked as not trusted`
- Happens after the CA is renewed or a replica is rebuilt

**Fix (on each client)**
```bash
sudo ipa-certupdate
sudo systemctl restart sssd
```

**Prevention:** run `ipa-certupdate` across all clients via Ansible after any CA change.

---

### 🟠 Category B: Time and Clock Failures

---

#### Failure 4: Clock skew breaks Kerberos

**Symptoms**
- `kinit: Clock skew too great while getting initial credentials`
- Logins work on some machines, fail on others
- Failures appear and disappear seemingly randomly

**Why it happens**
Kerberos tickets carry timestamps. If client and server clocks differ by more than 300 seconds (5 minutes), the KDC rejects the request as a possible replay attack.

Common causes: VM suspended and resumed, chronyd not running, firewall blocking NTP (UDP 123), virtualization host clock drift.

**Diagnosis**
```bash
chronyc tracking
chronyc sources -v
date; ssh ipa1 date      # compare directly
```

**Fix**
```bash
sudo systemctl enable --now chronyd
sudo chronyc makestep     # force immediate correction
sudo firewall-cmd --permanent --add-service=ntp && sudo firewall-cmd --reload
```

**Prevention:** point every machine in the domain at the same NTP source, ideally the IPA servers themselves. Monitor `chronyc tracking` offset with your monitoring system and alert above 1 second.

---

### 🔴 Category C: Database (389-DS) Failures

---

#### Failure 5: Disk full on /var

**Symptoms**
- 389-ds refuses to start or goes read-only
- Errors log: `No space left on device`
- Everything breaks simultaneously

**Why it happens**
IPA logs are verbose. The 389-ds access log alone can produce gigabytes per day on a busy server. Dogtag debug logs are worse. Nobody sets up rotation, and six months later the disk is full.

**Immediate fix**
```bash
df -h /var
sudo du -sh /var/log/dirsrv/* /var/log/pki/* /var/lib/dirsrv/*
sudo journalctl --vacuum-size=500M
sudo find /var/log/dirsrv -name "access.2*" -mtime +7 -delete
sudo systemctl restart dirsrv@REALM
```

**Prevention** — configure log rotation *inside* 389-ds, not just logrotate:
```bash
ldapmodify -x -D "cn=Directory Manager" -W <<EOF
dn: cn=config
changetype: modify
replace: nsslapd-accesslog-maxlogsperdir
nsslapd-accesslog-maxlogsperdir: 10
-
replace: nsslapd-accesslog-logmaxdiskspace
nsslapd-accesslog-logmaxdiskspace: 2000
-
replace: nsslapd-accesslog-logexpirationtime
nsslapd-accesslog-logexpirationtime: 7
EOF
```

Also put `/var/log` and `/var/lib/dirsrv` on separate filesystems so a log explosion can't take down the database.

---

#### Failure 6: LMDB map size exhausted (RHEL 10+)

**Symptoms**
- `MDB_MAP_FULL: Environment mapsize limit reached`
- Writes fail while reads still work — very confusing

**Why it happens**
RHEL 10's 389-ds uses LMDB, which pre-allocates a fixed maximum database size. Grow past it and writes stop dead.

**Fix**
```bash
sudo dsconf slapd-REALM backend config get | grep -i mapsize
sudo systemctl stop dirsrv@REALM
sudo dsconf slapd-REALM backend config set --mapsize 8589934592   # 8 GB
sudo systemctl start dirsrv@REALM
```

**Prevention:** set map size to roughly 3× your expected database size at install time, and monitor actual usage.

---

#### Failure 7: Database corruption after unclean shutdown

**Symptoms**
- 389-ds won't start
- Errors log mentions corrupt index or database recovery failure

**Fix**
```bash
sudo systemctl stop dirsrv@REALM
# Try reindexing first — less destructive
sudo dsctl slapd-REALM db2index
sudo systemctl start dirsrv@REALM

# If that fails, restore from backup
sudo dsctl slapd-REALM bak2db /var/lib/dirsrv/slapd-REALM/bak/LATEST
```

**Prevention:** never `kill -9` the dirsrv process. Always use `ipactl stop`. Configure your VM host and UPS for graceful shutdown.

---

#### Failure 8: Too many open connections / file descriptor exhaustion

**Symptoms**
- New LDAP connections refused
- Errors log: `Too many open files`
- Performance degrades progressively

**Fix**
```bash
# Raise the systemd limit
sudo systemctl edit dirsrv@REALM
# Add:
# [Service]
# LimitNOFILE=16384

sudo systemctl daemon-reload
sudo systemctl restart dirsrv@REALM
```

Also raise the internal limit:
```bash
sudo dsconf slapd-REALM config replace nsslapd-maxdescriptors=16384
```

---

### 🟠 Category D: Replication Failures

---

#### Failure 9: Replication agreement broken

**Symptoms**
- Changes made on server A never appear on server B
- Users can log in on one server but not another
- Passwords change on one server, old password still works on another

**Diagnosis**
```bash
sudo ipa-replica-manage list -v ipa1.lab.example.com
# Look for: "last update status" — anything other than "Error (0)" is a problem
```

**Fix**
```bash
# Force a re-sync (pull everything from a known-good server)
sudo ipa-replica-manage re-initialize --from=ipa1.lab.example.com

# If the agreement is truly broken, remove and recreate
sudo ipa-replica-manage del ipa2.lab.example.com --force
sudo ipa-replica-manage connect ipa1.lab.example.com ipa2.lab.example.com
```

⚠️ **Critical warning:** `re-initialize` *wipes* the target server's database and copies from the source. Any change that existed only on the target is destroyed. Always re-initialize *from* the server with the most correct data.

---

#### Failure 10: Replication conflict entries

**Symptoms**
- Duplicate-looking users in the directory
- `ipa user-show` behaves inconsistently
- Entries with weird DNs containing `nsuniqueid`

**Why it happens**
Two administrators created the same object on two servers at nearly the same moment. Replication can't decide which is real, so it keeps both and flags the conflict.

**Diagnosis**
```bash
ldapsearch -x -D "cn=Directory Manager" -W \
  -b "dc=lab,dc=example,dc=com" "(nsds5ReplConflict=*)" dn
```

**Fix**
```bash
# Keep the correct one, delete the conflict copy
ldapdelete -x -D "cn=Directory Manager" -W \
  "nsuniqueid=abc123...+uid=jsmith,cn=users,cn=accounts,dc=lab,dc=example,dc=com"
```

**Prevention:** designate one server as the primary write target for administrative changes. Point your automation at it specifically.

---

#### Failure 11: Replication topology became a star (single point of failure)

**Symptoms**
- Not an immediate failure — a latent one
- When the hub server dies, all replication stops

**Diagnosis**
```bash
ipa topologysegment-find domain
ipa topologysuffix-verify domain
```

**Fix** — build a ring or mesh so every server has at least two paths:
```bash
ipa topologysegment-add domain --leftnode=ipa2.lab.example.com \
  --rightnode=ipa3.lab.example.com
```

**Best practice:** every replica should have **at least 2** replication agreements. No more than 4 to avoid excessive traffic.

---

#### Failure 12: RUV (Replica Update Vector) from a deleted server

**Symptoms**
- Replication is slow or stalls
- Logs reference a replica ID that no longer exists
- Happens after decommissioning a server incorrectly

**Diagnosis**
```bash
sudo ipa-replica-manage list-ruv
```

**Fix**
```bash
sudo ipa-replica-manage clean-ruv REPLICA_ID
# If that hangs:
sudo ipa-replica-manage abort-clean-ruv REPLICA_ID
```

**Prevention:** always decommission with `ipa server-del <hostname>` *before* powering off the machine. Never just delete the VM.

---

### 🟡 Category E: DNS Failures

---

#### Failure 13: SRV records missing or wrong

**Symptoms**
- `ipa-client-install` can't auto-discover the server
- `Domain not found` errors
- SSSD fails to locate the KDC

**Diagnosis**
```bash
dig +short -t SRV _kerberos._tcp.lab.example.com
dig +short -t SRV _ldap._tcp.lab.example.com
```

**Fix**
```bash
kinit admin
ipa dns-update-system-records
ipa dns-update-system-records --dry-run   # preview first
```

---

#### Failure 14: NetworkManager overwrites /etc/resolv.conf

**Symptoms**
- DNS works, then stops after a reboot or network change
- `/etc/resolv.conf` suddenly points at your ISP's DNS or a DHCP-provided server

**Why it happens**
NetworkManager helpfully "fixes" resolv.conf based on DHCP. This is a known, recurring IPA issue — it was addressed in FreeIPA test suites as recently as version 4.13.2.

**Fix**
```bash
# Pin DNS on the connection
sudo nmcli con mod "System eth0" ipv4.dns "192.168.10.10"
sudo nmcli con mod "System eth0" ipv4.ignore-auto-dns yes
sudo nmcli con up "System eth0"
```

Or lock the file entirely (blunt but effective):
```bash
sudo chattr +i /etc/resolv.conf
```

---

#### Failure 15: DNSSEC signing failure

**Symptoms**
- `ipa-dnskeysyncd` fails to start
- DNS zones fail validation
- Historically broken by SoftHSM version changes — a known issue with SoftHSM 2.7.0-rc1 as of FreeIPA 4.13.2

**Fix**
```bash
sudo systemctl status ipa-dnskeysyncd
sudo journalctl -u ipa-dnskeysyncd -n 100

# If keys are corrupt, disable DNSSEC on the zone temporarily
ipa dnszone-mod lab.example.com --dnssec=false
```

---

### 🟡 Category F: Client-Side Failures

---

#### Failure 16: SSSD cache poisoned/stale

**Symptoms**
- User exists in IPA but `id username` says "no such user"
- Deleted user can still log in
- Group membership changes don't take effect

**Fix**
```bash
sudo sss_cache -E                    # invalidate everything
sudo systemctl stop sssd
sudo rm -f /var/lib/sss/db/*         # nuclear option
sudo systemctl start sssd
id username
```

⚠️ Deleting the cache means offline authentication won't work until users log in again while online.

---

#### Failure 17: Host keytab is broken or out of sync

**Symptoms**
- `kinit -k` fails with `Key table entry not found`
- SSSD can't authenticate to the server
- Usually follows a host being re-created in IPA

**Fix**
```bash
sudo klist -kt /etc/krb5.keytab
sudo ipa-getkeytab -s ipa1.lab.example.com \
  -p host/$(hostname) -k /etc/krb5.keytab
sudo systemctl restart sssd
```

If that fails, re-enroll from scratch:
```bash
sudo ipa-client-install --uninstall
sudo ipa-client-install --mkhomedir --principal admin
```

---

#### Failure 18: No home directory on login

**Symptoms**
- Login succeeds but shell starts in `/` with "Could not chdir to home directory"

**Fix**
```bash
sudo authselect select sssd with-mkhomedir --force
sudo systemctl enable --now oddjobd
```

**Prevention:** always pass `--mkhomedir` to `ipa-client-install`.

---

#### Failure 19: HBAC rule blocks legitimate access

**Symptoms**
- Password is correct but login is refused
- `/var/log/secure` shows `Access denied by HBAC rules`

**Diagnosis**
```bash
ipa hbactest --user=jsmith --host=webserver.lab.example.com --service=sshd
ipa hbacrule-find
```

**Fix**
```bash
ipa hbacrule-add allow_devs --desc="Developers to web servers"
ipa hbacrule-add-user allow_devs --groups=developers
ipa hbacrule-add-host allow_devs --hostgroups=webservers
ipa hbacrule-add-service allow_devs --hbacsvcs=sshd
```

**Note:** IPA ships with a rule called `allow_all` enabled by default. Many admins disable it for security and then wonder why nobody can log in. Build your replacement rules *before* disabling it.

---

### 🟡 Category G: Upgrade and Migration Failures

---

#### Failure 20: ipa-server-upgrade fails mid-run

**Symptoms**
- Upgrade aborts, IPA is in a half-upgraded state
- Services won't start

**Fix**
```bash
sudo tail -100 /var/log/ipaupgrade.log
sudo ipa-server-upgrade      # it's designed to be re-runnable
sudo ipactl restart
```

**Prevention:** always `ipa-backup` immediately before upgrading. Upgrade one replica at a time, verifying between each.

---

#### Failure 21: Mixed-version deployment drift

**Symptoms**
- Features work on one server and not another
- Replication schema errors
- FIPS-mode replica installs fail across major versions (fixed in FreeIPA 4.13.2 for RHEL 8.10 → 9.8)

**Fix:** finish the migration. Red Hat's guidance is explicit — migrate all servers **as quickly as possible**, because extended mixed-version operation causes incompatibilities.

**Important for RHEL 9→10:** in-place upgrades of IdM servers are **not supported**. You must add new RHEL 10 replicas, transfer CA and CRL roles, then retire the old servers.

---

#### Failure 22: Winbind fails to restart after upgrade

**Symptoms**
- `ipactl restart` fails at the winbind stage
- AD trust stops working
- Specifically seen upgrading RHEL 9.7 → 9.8 (fixed in FreeIPA 4.13.1)

**Fix**
```bash
sudo systemctl restart winbind
sudo ipactl restart
sudo ipa-healthcheck --source ipahealthcheck.ipa.trust
```

---

### 🟡 Category H: Resource and Performance Failures

---

#### Failure 23: Memory exhaustion / OOM killer

**Symptoms**
- Random service deaths
- `dmesg` shows `Out of memory: Killed process ... ns-slapd`
- Java heap errors from pki-tomcatd

**Why it happens**
IPA is memory-hungry. 389-ds caches aggressively, and Dogtag runs a JVM. On a 4 GB box under load, they fight and the kernel picks a loser.

**Fix**
```bash
# Cap the 389-ds entry cache
sudo dsconf slapd-REALM backend suffix set --suffix="dc=lab,dc=example,dc=com" \
  --cache-memsize=1073741824

# Cap the Dogtag JVM
sudo vi /etc/sysconfig/pki-tomcat
# JAVA_OPTS="-Xms512m -Xmx2048m"
sudo systemctl restart pki-tomcatd@pki-tomcat
```

**Prevention:** 8 GB minimum for production. Monitor memory and alert at 85%.

---

#### Failure 24: Memory leaks in IPA plugins

**Symptoms**
- 389-ds memory grows steadily over days/weeks
- Eventually OOM-killed

**Status:** FreeIPA 4.13.1 fixed a large batch of memory leaks across `ipa-pwd-extop`, `ipa-lockout`, `ipa-sidgen`, `ipa-extdom-extop`, `ipa-range-check`, `ipa-graceperiod`, `ipa-enrollment`, and the topology plugin.

**Fix:** upgrade to 4.13.1 or later. If you can't upgrade immediately, schedule a monthly rolling restart of `dirsrv` across replicas as a stopgap.

---

#### Failure 25: SELinux denials blocking services

**Symptoms**
- Service fails to start with permission errors despite correct file permissions
- `ausearch -m avc -ts recent` shows denials

**Fix**
```bash
sudo ausearch -m avc -ts recent | audit2why
sudo restorecon -Rv /etc/ipa /var/lib/ipa /var/lib/dirsrv
sudo setsebool -P httpd_can_network_connect on
```

**Never** disable SELinux to fix IPA. Fix the context or add a policy module. FreeIPA 4.13.2 expanded SELinux policy coverage for SSSD MFA helpers and Kerberos usage specifically because of these issues.

---

### Quick failure lookup table

| Symptom | Most likely cause | First command to run |
|---|---|---|
| Web UI 500 error | Expired certs | `sudo ipa-cert-fix` |
| `Clock skew too great` | Time drift | `chronyc makestep` |
| User exists but `id` fails | SSSD cache | `sss_cache -E` |
| Changes don't replicate | Broken agreement | `ipa-replica-manage list -v` |
| Client can't find server | Missing SRV records | `ipa dns-update-system-records` |
| Login refused, password OK | HBAC rule | `ipa hbactest ...` |
| Service randomly dies | OOM | `dmesg \| grep -i oom` |
| Everything is down | Disk full | `df -h /var` |
| `Key table entry not found` | Broken keytab | `ipa-getkeytab ...` |
| Duplicate users appearing | Replication conflict | `ldapsearch "(nsds5ReplConflict=*)"` |


---

## 7. Automating Recovery: Scripts That Fix Things While You Sleep

### The philosophy first

Before writing a single line of automation, understand this rule:

> **Automate the safe things. Alert on the dangerous things.**

Restarting a stopped service is safe — worst case, it stays down and you get an alert. Re-initializing replication is *dangerous* — it deletes data. Never automate anything that can destroy data without a human looking at it.

Here's the split:

| ✅ Safe to automate | ❌ Never automate |
|---|---|
| Restarting stopped services | Replication re-initialization |
| Clearing SSSD cache | Deleting conflict entries |
| Rotating and cleaning logs | Certificate authority recovery |
| Forcing time re-sync | `ipa-server-upgrade` |
| Running health checks | Removing replicas |
| Sending alerts | Restoring from backup |

### Layer 1: Let systemd do the easy work

The simplest automation requires no scripts at all. systemd can restart failed services by itself.

```bash
sudo mkdir -p /etc/systemd/system/dirsrv@.service.d
sudo tee /etc/systemd/system/dirsrv@.service.d/restart.conf << 'EOF'
[Service]
Restart=on-failure
RestartSec=30
StartLimitBurst=5
StartLimitIntervalSec=600
EOF
```

Repeat for the others:

```bash
for svc in httpd krb5kdc kadmin named pki-tomcatd@pki-tomcat ipa-custodia ipa-otpd; do
  sudo mkdir -p /etc/systemd/system/${svc}.service.d
  sudo tee /etc/systemd/system/${svc}.service.d/restart.conf << 'EOF'
[Service]
Restart=on-failure
RestartSec=30
StartLimitBurst=5
StartLimitIntervalSec=600
EOF
done

sudo systemctl daemon-reload
```

**What the settings mean:**
- `Restart=on-failure` — restart if it crashes, but not if you stopped it deliberately
- `RestartSec=30` — wait 30 seconds between attempts (gives dependencies time)
- `StartLimitBurst=5` / `StartLimitIntervalSec=600` — if it fails 5 times in 10 minutes, give up and stay down

That last part is crucial. Infinite restart loops hide real problems and hammer your logs. Failing loudly after 5 attempts is correct behavior.

### Layer 2: The IPA-aware watchdog script

systemd doesn't understand IPA's service dependencies. `ipactl` does. This script bridges the gap.

```bash
sudo tee /usr/local/sbin/ipa-watchdog.sh << 'SCRIPT'
#!/usr/bin/env bash
#
# ipa-watchdog.sh — detect and recover common IPA service failures
# Runs every 5 minutes via systemd timer.
# Philosophy: fix safe things, alert on everything else.
#
set -uo pipefail

ALERT_EMAIL="ipa-admins@example.com"
STATE_DIR="/var/lib/ipa-watchdog"
LOCK_FILE="/var/run/ipa-watchdog.lock"
MAX_RESTARTS_PER_HOUR=3
LOG_TAG="ipa-watchdog"

mkdir -p "$STATE_DIR"

log() { logger -t "$LOG_TAG" -- "$*"; echo "[$(date -Is)] $*"; }

alert() {
  local subject="$1" body="$2"
  log "ALERT: $subject"
  if command -v mail >/dev/null 2>&1; then
    printf '%s\n' "$body" | mail -s "[IPA] $subject on $(hostname -f)" "$ALERT_EMAIL"
  fi
}

# Prevent overlapping runs
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log "Another instance is running; exiting."
  exit 0
fi

# --- Rate limiting: don't restart endlessly ---
restart_budget_ok() {
  local svc="$1"
  local counter="$STATE_DIR/restarts_${svc//\//_}"
  local now hour_ago count=0
  now=$(date +%s); hour_ago=$((now - 3600))

  # Prune entries older than one hour FIRST, then count what remains
  if [[ -f "$counter" ]]; then
    awk -v t="$hour_ago" '$1 > t' "$counter" > "${counter}.tmp" 2>/dev/null \
      && mv "${counter}.tmp" "$counter"
    count=$(wc -l < "$counter")
  fi

  if (( count >= MAX_RESTARTS_PER_HOUR )); then
    return 1
  fi
  echo "$now" >> "$counter"
  return 0
}

# ============================================================
# CHECK 1: Disk space — must run FIRST
# A full disk causes cascading failures. Restarting won't help.
# ============================================================
check_disk() {
  local pct
  pct=$(df --output=pcent /var | tail -1 | tr -dc '0-9')
  if (( pct >= 95 )); then
    alert "CRITICAL: /var is ${pct}% full" \
      "Disk nearly full. Services will fail. Emergency cleanup running.
$(df -h /var)
Largest consumers:
$(du -sh /var/log/dirsrv/* /var/log/pki/* 2>/dev/null | sort -rh | head -10)"

    # Safe emergency cleanup only
    journalctl --vacuum-size=200M >/dev/null 2>&1
    find /var/log/dirsrv -name "access.2*" -mtime +3 -delete 2>/dev/null
    find /var/log/pki -name "*.log.2*" -mtime +3 -delete 2>/dev/null
    return 1
  elif (( pct >= 85 )); then
    alert "WARNING: /var is ${pct}% full" "$(df -h /var)"
  fi
  return 0
}

# ============================================================
# CHECK 2: Time synchronization
# ============================================================
check_time() {
  if ! systemctl is-active --quiet chronyd; then
    log "chronyd is down — starting it"
    systemctl start chronyd
    sleep 5
  fi

  # chronyc prints e.g. "System time : 0.000123456 seconds slow of NTP time"
  # The magnitude is always positive; "fast"/"slow" gives the direction.
  # A server running FAST breaks Kerberos exactly as badly as one running slow,
  # so we compare the ABSOLUTE value.
  local offset
  offset=$(chronyc tracking 2>/dev/null | awk '/System time/ {print $4}')
  [[ -z "$offset" ]] && return 0

  # abs() the value so negative/fast offsets are caught too
  if awk -v o="$offset" 'BEGIN{if(o<0)o=-o; exit !(o > 1.0)}'; then
    log "Clock offset ${offset}s exceeds threshold — forcing makestep"
    chronyc makestep >/dev/null 2>&1
    sleep 3
    local after
    after=$(chronyc tracking 2>/dev/null | awk '/System time/ {print $4}')
    if awk -v o="$after" 'BEGIN{if(o<0)o=-o; exit !(o > 1.0)}'; then
      alert "Clock skew persists: ${after}s" \
        "Kerberos fails above 300s skew in EITHER direction.
$(chronyc tracking)
$(chronyc sources -v)"
    fi
  fi
}

# ============================================================
# CHECK 3: IPA services via ipactl (dependency-aware)
# ============================================================
check_ipa_services() {
  local status_out failed
  status_out=$(ipactl status 2>&1)

  if echo "$status_out" | grep -q "STOPPED"; then
    failed=$(echo "$status_out" | awk '/STOPPED/ {print $1}' | tr '\n' ' ')
    log "Stopped IPA services detected: $failed"

    if ! restart_budget_ok "ipactl"; then
      alert "IPA restart budget exhausted" \
        "Services still failing after $MAX_RESTARTS_PER_HOUR restarts this hour.
MANUAL INTERVENTION REQUIRED.

$status_out

Recent httpd errors:
$(tail -30 /var/log/httpd/error_log 2>/dev/null)

Recent dirsrv errors:
$(tail -30 /var/log/dirsrv/slapd-*/errors 2>/dev/null)"
      return 1
    fi

    log "Attempting: ipactl start"
    if ipactl start >/dev/null 2>&1; then
      sleep 20
      if ipactl status 2>&1 | grep -q "STOPPED"; then
        log "Partial recovery; escalating to full restart"
        ipactl restart >/dev/null 2>&1
        sleep 30
      fi
    fi

    if ipactl status 2>&1 | grep -q "STOPPED"; then
      alert "IPA services failed to recover" "$(ipactl status 2>&1)"
      return 1
    else
      alert "IPA services recovered automatically" \
        "Previously stopped: $failed — now running. Investigate root cause."
    fi
  fi
  return 0
}

# ============================================================
# CHECK 4: Functional test — can we actually authenticate?
# A service can be "running" and still be useless.
# ============================================================
check_functional() {
  local keytab="/etc/krb5.keytab"
  export KRB5CCNAME="/tmp/ipa-watchdog-ccache"

  if ! kinit -k -t "$keytab" "host/$(hostname -f)" >/dev/null 2>&1; then
    alert "Kerberos functional test FAILED" \
      "Cannot obtain a TGT using the host keytab.
This means authentication is broken even if services appear up.

$(klist -kt $keytab 2>&1 | head -20)
$(tail -30 /var/log/krb5kdc.log 2>/dev/null)"
    kdestroy >/dev/null 2>&1
    return 1
  fi

  # LDAP read test
  if ! ldapsearch -Y GSSAPI -H "ldap://$(hostname -f)" \
       -b "cn=users,cn=accounts,$(ipa env basedn 2>/dev/null | awk '{print $2}')" \
       -s one "(uid=admin)" dn >/dev/null 2>&1; then
    alert "LDAP functional test FAILED" \
      "Kerberos works but LDAP queries fail.
$(tail -30 /var/log/dirsrv/slapd-*/errors 2>/dev/null)"
    kdestroy >/dev/null 2>&1
    return 1
  fi

  kdestroy >/dev/null 2>&1
  return 0
}

# ============================================================
# CHECK 5: Certificate expiry (alert only — NEVER auto-fix)
# ============================================================
check_certs() {
  local now warn_at
  now=$(date +%s)
  warn_at=$((now + 30*86400))

  local expiring=""
  while read -r line; do
    local expdate expts
    expdate=$(echo "$line" | sed 's/.*expires: //')
    expts=$(date -d "$expdate" +%s 2>/dev/null) || continue
    if (( expts < warn_at )); then
      expiring+="$line"$'\n'
    fi
  done < <(getcert list 2>/dev/null | grep "expires:")

  if [[ -n "$expiring" ]]; then
    alert "Certificates expiring within 30 days" \
      "DO NOT IGNORE. Expired IPA certificates cause total outage.

$expiring

Full status:
$(getcert list 2>/dev/null | grep -E 'Request ID|status:|expires:')

Remediation: sudo ipa-cert-fix"
  fi

  # Also catch certmonger not tracking anything
  local tracked
  tracked=$(getcert list 2>/dev/null | grep -c "status: MONITORING")
  if (( tracked < 5 )); then
    alert "Certmonger tracking only $tracked certificates" \
      "Expected 8+. Certificates may not renew automatically.
Remediation: sudo ipa-certupdate && sudo systemctl restart certmonger"
  fi
}

# ============================================================
# CHECK 6: Replication health (alert only — NEVER auto-fix)
# ============================================================
check_replication() {
  command -v ipa-replica-manage >/dev/null 2>&1 || return 0

  local repl_out
  repl_out=$(ipa-replica-manage list -v "$(hostname -f)" 2>/dev/null)
  [[ -z "$repl_out" ]] && return 0

  if echo "$repl_out" | grep -qi "error" && \
     ! echo "$repl_out" | grep -q "Error (0)"; then
    alert "Replication errors detected" \
      "Replication is failing. Data will diverge between servers.
DO NOT run re-initialize without confirming which server has correct data.

$repl_out"
  fi

  # Conflict entries
  local conflicts
  conflicts=$(ldapsearch -Y GSSAPI -H "ldap://$(hostname -f)" \
    -b "$(ipa env basedn 2>/dev/null | awk '{print $2}')" \
    "(nsds5ReplConflict=*)" dn 2>/dev/null | grep -c "^dn:")
  if (( conflicts > 0 )); then
    alert "$conflicts replication conflict entries found" \
      "Manual review required. Run:
ldapsearch -x -D 'cn=Directory Manager' -W -b BASEDN '(nsds5ReplConflict=*)' dn"
  fi
}

# ============================================================
# CHECK 7: Memory pressure
# ============================================================
check_memory() {
  local pct
  pct=$(free | awk '/Mem:/ {printf "%.0f", $3/$2 * 100}')
  if (( pct >= 90 )); then
    alert "Memory at ${pct}%" \
      "OOM killer may terminate IPA services.
$(free -h)
Top consumers:
$(ps aux --sort=-%mem | head -8)"
  fi

  if dmesg 2>/dev/null | tail -200 | grep -qi "out of memory.*ns-slapd\|out of memory.*java"; then
    alert "OOM killer terminated an IPA process" \
      "$(dmesg | grep -i 'out of memory' | tail -5)"
  fi
}

# ============================================================
# MAIN
# ============================================================
main() {
  log "Watchdog run starting"

  # Disk first — if it's full, nothing else will work
  if ! check_disk; then
    log "Disk critical; skipping service restarts (they would fail anyway)"
    exit 1
  fi

  check_time
  check_ipa_services || exit 1
  check_functional
  check_certs
  check_replication
  check_memory

  log "Watchdog run complete"
}

main "$@"
SCRIPT

sudo chmod 750 /usr/local/sbin/ipa-watchdog.sh
```

**Install it as a systemd timer** (better than cron — it logs to the journal and handles missed runs):

```bash
sudo tee /etc/systemd/system/ipa-watchdog.service << 'EOF'
[Unit]
Description=IPA health watchdog and auto-recovery
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ipa-watchdog.sh
TimeoutStartSec=600
EOF

sudo tee /etc/systemd/system/ipa-watchdog.timer << 'EOF'
[Unit]
Description=Run IPA watchdog every 5 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
RandomizedDelaySec=30
Persistent=true

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now ipa-watchdog.timer
sudo systemctl list-timers ipa-watchdog.timer
```

> **Why `RandomizedDelaySec`?** If you have five replicas all running this on the same schedule, they'd all hit the LDAP servers at the same instant. The random jitter spreads the load out.

### Layer 3: Weekly deep health check

The watchdog handles urgent problems. This one catches slow-burning issues.

```bash
sudo tee /usr/local/sbin/ipa-weekly-health.sh << 'SCRIPT'
#!/usr/bin/env bash
set -uo pipefail

REPORT="/var/log/ipa-health-$(date +%F).json"
HUMAN="/tmp/ipa-health-$(date +%F).txt"
EMAIL="ipa-admins@example.com"

{
  echo "IPA Weekly Health Report — $(hostname -f) — $(date)"
  echo "================================================================"
  echo
  echo "## Service status"
  ipactl status 2>&1
  echo
  echo "## Certificate status"
  getcert list 2>/dev/null | grep -E 'Request ID|status:|expires:|subject:'
  echo
  echo "## Replication topology"
  ipa topologysegment-find domain 2>/dev/null
  echo
  echo "## Replication agreements"
  ipa-replica-manage list -v "$(hostname -f)" 2>/dev/null
  echo
  echo "## Disk usage"
  df -h /var /var/log /var/lib/dirsrv 2>/dev/null
  echo
  echo "## Database size"
  du -sh /var/lib/dirsrv/slapd-*/ 2>/dev/null
  echo
  echo "## Memory"
  free -h
  echo
  echo "## ipa-healthcheck failures"
  ipa-healthcheck --failures-only --output-type human 2>&1 || echo "(healthcheck not installed)"
} > "$HUMAN" 2>&1

# Machine-readable version for monitoring ingestion
ipa-healthcheck --output-type json --output-file "$REPORT" 2>/dev/null

# Keep 90 days
find /var/log -name "ipa-health-*.json" -mtime +90 -delete 2>/dev/null

mail -s "IPA Weekly Health — $(hostname -s)" "$EMAIL" < "$HUMAN"
cat "$HUMAN"
SCRIPT

sudo chmod 750 /usr/local/sbin/ipa-weekly-health.sh
```

Schedule it:

```bash
sudo tee /etc/systemd/system/ipa-weekly-health.timer << 'EOF'
[Unit]
Description=Weekly IPA deep health report

[Timer]
OnCalendar=Mon 06:00
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF

sudo tee /etc/systemd/system/ipa-weekly-health.service << 'EOF'
[Unit]
Description=Weekly IPA deep health report

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ipa-weekly-health.sh
TimeoutStartSec=1800
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now ipa-weekly-health.timer
```

### Layer 4: Client-side self-healing

Clients fail differently than servers. This runs on every enrolled machine.

```bash
sudo tee /usr/local/sbin/ipa-client-selfheal.sh << 'SCRIPT'
#!/usr/bin/env bash
set -uo pipefail

log() { logger -t ipa-client-selfheal -- "$*"; }

# 1. SSSD alive?
if ! systemctl is-active --quiet sssd; then
  log "SSSD down — restarting"
  systemctl restart sssd
  sleep 5
fi

# 2. Can we resolve a known IPA user? (functional, not just "is it running")
if ! id admin >/dev/null 2>&1; then
  log "Cannot resolve IPA users — clearing SSSD cache"
  sss_cache -E
  systemctl restart sssd
  sleep 10

  if ! id admin >/dev/null 2>&1; then
    log "Still failing after cache clear — checking keytab"
    if ! kinit -k -t /etc/krb5.keytab "host/$(hostname -f)" >/dev/null 2>&1; then
      log "CRITICAL: host keytab is broken. Manual re-enrollment needed."
      logger -p daemon.crit -t ipa-client-selfheal \
        "Host keytab invalid on $(hostname -f). Run: ipa-client-install --uninstall && ipa-client-install"
    fi
    kdestroy >/dev/null 2>&1
  fi
fi

# 3. Is DNS still pointing at IPA?
if ! grep -q "$(awk -F= '/^server =/ {print $2}' /etc/ipa/default.conf 2>/dev/null | tr -d ' ')" \
     /etc/resolv.conf 2>/dev/null; then
  log "WARNING: resolv.conf may have been overwritten by NetworkManager"
fi

# 4. Time sync
if ! systemctl is-active --quiet chronyd; then
  log "chronyd down — starting"
  systemctl start chronyd
fi
SCRIPT

sudo chmod 750 /usr/local/sbin/ipa-client-selfheal.sh
```

Run it every 10 minutes via a timer using the same pattern as above.

### Layer 5: Ansible for fleet-wide operations

When you have 200 clients, you don't SSH to each one. Red Hat maintains the official `ansible-freeipa` collection.

```bash
ansible-galaxy collection install freeipa.ansible_freeipa
```

**Example: refresh certificates everywhere after a CA change**

```yaml
---
- name: Refresh IPA CA trust on all clients
  hosts: ipa_clients
  become: true
  serial: "20%"          # roll through in batches — never all at once
  tasks:
    - name: Run ipa-certupdate
      ansible.builtin.command: /usr/sbin/ipa-certupdate
      register: certupdate
      changed_when: "'Systemwide CA database updated' in certupdate.stdout"

    - name: Restart SSSD
      ansible.builtin.systemd:
        name: sssd
        state: restarted

    - name: Verify user resolution still works
      ansible.builtin.command: id admin
      changed_when: false
      retries: 3
      delay: 5
```

**Example: rolling restart to work around memory leaks**

```yaml
---
- name: Rolling restart of IPA servers
  hosts: ipa_servers
  become: true
  serial: 1              # ONE at a time — never break quorum
  tasks:
    - name: Verify other replicas are healthy first
      ansible.builtin.command: ipa-healthcheck --failures-only
      register: hc
      failed_when: hc.rc not in [0, 1]
      delegate_to: "{{ groups['ipa_servers'] | difference([inventory_hostname]) | first }}"

    - name: Restart IPA
      ansible.builtin.command: ipactl restart

    - name: Wait for services
      ansible.builtin.wait_for:
        port: 636
        delay: 20
        timeout: 300

    - name: Confirm healthy before moving to next host
      ansible.builtin.command: ipactl status
      register: status
      until: "'STOPPED' not in status.stdout"
      retries: 10
      delay: 15
```

> **The `serial: 1` line is the most important thing in that file.** Restarting all your IPA servers simultaneously means a total authentication outage. One at a time, always.

### The escalation ladder

Put this on your wall:

```
Level 0 — systemd auto-restart          (0 seconds, no human)
   ↓ still broken after 5 tries
Level 1 — watchdog ipactl restart       (≤5 minutes, no human)
   ↓ still broken
Level 2 — email/page on-call            (≤5 minutes, human alerted)
   ↓ certificate or replication issue
Level 3 — documented manual runbook     (human executes known fix)
   ↓ data loss or CA destroyed
Level 4 — restore from backup           (human + change approval)
```


---

## 8. Monitoring: Knowing Before Your Users Do

### What to actually monitor

Most people monitor the wrong things. "Is the process running?" tells you almost nothing — a process can be running and completely broken. Monitor **outcomes**, not processes.

| Priority | Check | Threshold | Why |
|---|---|---|---|
| 🔴 P1 | Can a test user get a Kerberos ticket? | Fail = page | The actual thing users need |
| 🔴 P1 | Can LDAP answer an authenticated query? | Fail = page | Same |
| 🔴 P1 | `/var` disk usage | >90% = page | Causes cascading failure |
| 🔴 P1 | Certificate expiry | <30 days = page | Total outage when it hits |
| 🟠 P2 | Replication error status | Any error = alert | Silent data divergence |
| 🟠 P2 | Clock offset | >1 sec = alert | Precursor to Kerberos failure |
| 🟠 P2 | Memory usage | >85% = alert | OOM risk |
| 🟡 P3 | LDAP query response time | >500ms = ticket | Performance degradation |
| 🟡 P3 | `ipa-healthcheck` failures | Any = ticket | Catches everything else |
| 🟡 P3 | Replication lag | >60 sec = ticket | Growing divergence |

### Prometheus exporter

A simple textfile-collector script for node_exporter:

```bash
sudo tee /usr/local/sbin/ipa-metrics.sh << 'SCRIPT'
#!/usr/bin/env bash
OUT="/var/lib/node_exporter/textfile_collector/ipa.prom"
TMP="${OUT}.$$"

{
  echo "# HELP ipa_service_up IPA service running (1) or not (0)"
  echo "# TYPE ipa_service_up gauge"
  ipactl status 2>/dev/null | grep -E "Service:" | while read -r line; do
    svc=$(echo "$line" | sed 's/ Service:.*//' | tr ' ' '_')
    state=$(echo "$line" | grep -q RUNNING && echo 1 || echo 0)
    echo "ipa_service_up{service=\"$svc\"} $state"
  done

  echo "# HELP ipa_cert_expiry_seconds Seconds until certificate expiry"
  echo "# TYPE ipa_cert_expiry_seconds gauge"
  now=$(date +%s)
  i=0
  getcert list 2>/dev/null | grep "expires:" | while read -r line; do
    exp=$(date -d "$(echo "$line" | sed 's/.*expires: //')" +%s 2>/dev/null) || continue
    echo "ipa_cert_expiry_seconds{cert_index=\"$i\"} $((exp - now))"
    i=$((i+1))
  done

  echo "# HELP ipa_kerberos_functional Host can obtain a TGT"
  echo "# TYPE ipa_kerberos_functional gauge"
  export KRB5CCNAME=/tmp/ipa-metrics-cc
  if kinit -k -t /etc/krb5.keytab "host/$(hostname -f)" >/dev/null 2>&1; then
    echo "ipa_kerberos_functional 1"
  else
    echo "ipa_kerberos_functional 0"
  fi
  kdestroy >/dev/null 2>&1

  echo "# HELP ipa_clock_offset_seconds NTP offset"
  echo "# TYPE ipa_clock_offset_seconds gauge"
  offset=$(chronyc tracking 2>/dev/null | awk '/System time/ {print $4}')
  echo "ipa_clock_offset_seconds ${offset:-0}"

  echo "# HELP ipa_replication_errors Count of replication agreements in error"
  echo "# TYPE ipa_replication_errors gauge"
  errs=$(ipa-replica-manage list -v "$(hostname -f)" 2>/dev/null | grep -c "Error ([1-9]")
  echo "ipa_replication_errors ${errs:-0}"

} > "$TMP" && mv "$TMP" "$OUT"
SCRIPT

sudo chmod 750 /usr/local/sbin/ipa-metrics.sh
```

### Prometheus alert rules

```yaml
groups:
  - name: freeipa
    rules:
      - alert: IPAServiceDown
        expr: ipa_service_up == 0
        for: 5m
        labels: { severity: critical }
        annotations:
          summary: "IPA service {{ $labels.service }} is down on {{ $labels.instance }}"

      - alert: IPAKerberosBroken
        expr: ipa_kerberos_functional == 0
        for: 3m
        labels: { severity: critical }
        annotations:
          summary: "Kerberos authentication is non-functional on {{ $labels.instance }}"

      - alert: IPACertExpiringSoon
        expr: ipa_cert_expiry_seconds < 2592000
        for: 1h
        labels: { severity: critical }
        annotations:
          summary: "IPA certificate expires in less than 30 days"
          description: "Run ipa-cert-fix. Expired certs cause total outage."

      - alert: IPAClockSkew
        expr: abs(ipa_clock_offset_seconds) > 1
        for: 10m
        labels: { severity: warning }
        annotations:
          summary: "Clock offset {{ $value }}s — Kerberos fails above 300s"

      - alert: IPAReplicationError
        expr: ipa_replication_errors > 0
        for: 15m
        labels: { severity: warning }
        annotations:
          summary: "Replication errors detected — data may be diverging"
```

### Synthetic end-to-end test

The best monitor is one that does exactly what a user does. Create a dedicated test account and actually log in with it:

```bash
# On the IPA server, one time:
kinit admin
ipa user-add monitortest --first=Monitor --last=Test --random
ipa pwpolicy-add monitoring --maxlife=0 --minlife=0 --priority=1
ipa group-add monitoring-users
ipa group-add-member monitoring-users --users=monitortest
```

```bash
#!/usr/bin/env bash
# Run from an EXTERNAL host — tests the full path
KRB5CCNAME=/tmp/synthetic-cc
if echo "$MONITOR_PASS" | kinit monitortest >/dev/null 2>&1; then
  echo "OK: full authentication path working"
  kdestroy; exit 0
else
  echo "CRITICAL: end-to-end authentication failed"
  exit 2
fi
```

Run this from a machine *outside* the IPA servers. It tests DNS, network, Kerberos, LDAP, and policy all at once — everything a real user depends on.

---

## 9. Backup and Disaster Recovery

### The two backup types

```bash
# Full backup — includes files AND database. Requires services stopped.
sudo ipa-backup

# Data-only — database only, services keep running.
sudo ipa-backup --data --online
```

Backups land in `/var/lib/ipa/backup/`.

| Type | Services down? | Restores what | Use when |
|---|---|---|---|
| Full | Yes (brief) | Everything including certs and config | Before upgrades, weekly |
| Data-only online | No | LDAP data only | Daily, no maintenance window |

### Automated backup script

```bash
sudo tee /usr/local/sbin/ipa-backup-rotate.sh << 'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

BACKUP_DIR="/var/lib/ipa/backup"
REMOTE="backup.example.com:/backups/ipa/$(hostname -s)"
RETAIN_DAYS=30
MODE="${1:-data}"

if [[ "$MODE" == "full" ]]; then
  ipa-backup
else
  ipa-backup --data --online
fi

LATEST=$(ls -1dt "$BACKUP_DIR"/ipa-* 2>/dev/null | head -1)
[[ -z "$LATEST" ]] && { echo "ERROR: no backup produced"; exit 1; }

# Verify it's not empty
SIZE=$(du -s "$LATEST" | cut -f1)
if (( SIZE < 1000 )); then
  echo "ERROR: backup suspiciously small (${SIZE}KB)" >&2
  exit 1
fi

# Ship it off-box — a backup on the same server is not a backup
rsync -az --delete-after "$LATEST" "$REMOTE/" || {
  echo "WARNING: offsite copy failed" >&2
}

# Prune local
find "$BACKUP_DIR" -maxdepth 1 -name "ipa-*" -mtime +$RETAIN_DAYS -exec rm -rf {} +

echo "Backup complete: $LATEST ($(du -sh "$LATEST" | cut -f1))"
SCRIPT

sudo chmod 750 /usr/local/sbin/ipa-backup-rotate.sh
```

Schedule: daily data-only at 02:00, full weekly on Sunday.

### The three disaster scenarios

**Scenario A: One replica died, others fine**

Don't restore. Rebuild.

```bash
# On a healthy server, remove the dead one
kinit admin
ipa server-del dead-server.lab.example.com
sudo ipa-replica-manage clean-ruv REPLICA_ID    # if RUV lingers

# Build a fresh replica
sudo ipa-client-install
sudo ipa-replica-install --setup-ca --setup-dns
```

**Scenario B: All servers lost, backup available**

```bash
# Fresh OS, same hostname and IP as the original
sudo dnf install -y ipa-server ipa-server-dns
# Copy backup to /var/lib/ipa/backup/
sudo ipa-restore ipa-full-2026-07-20-02-00-00
sudo ipactl start
sudo ipa-healthcheck
```

**Scenario C: The CA certificate expired**

This is the worst one. If `ipa-cert-fix` can't help, the documented recovery involves temporarily setting the system clock backward, renewing, then correcting the clock. It's genuinely painful and risky.

**Avoid ever reaching this scenario.** Monitor certificate expiry. That's the entire lesson.

### Test your restores

> A backup you have never restored is not a backup. It is a hope.

Quarterly, restore to an isolated VM and verify:

```bash
sudo ipa-restore --instance=... /path/to/backup
sudo ipactl start
kinit admin
ipa user-find
ipa-healthcheck --failures-only
```

Write down how long it took. That number is your actual RTO, not the one in your plan.

---

## 10. Alternatives: Is Something Else More Reliable?

### The honest framing

FreeIPA isn't *unreliable*. It's **complex**, and complexity creates failure modes. Nine interdependent services, a Java CA, DNS, and multi-master replication is a lot of moving parts.

The right question isn't "what's more reliable?" It's **"what's the simplest thing that does what I actually need?"** If you only need SSO for web apps, running a full Kerberos realm with a certificate authority is enormous overkill — and every unnecessary component is a component that can break.

### What FreeIPA is uniquely good at

Nothing else in the open-source world does all of these at once:

- Kerberos single sign-on for Linux hosts
- Host-based access control (which user on which machine)
- Centralized sudo rules
- Automatic host certificate enrollment via a built-in CA
- SSH key distribution
- Automount map management
- Cross-forest trust with Active Directory

If you need that *combination*, there is genuinely no drop-in replacement.

### The alternatives, honestly compared

#### Microsoft Entra ID (formerly Azure AD)

| | |
|---|---|
| **Best for** | Organizations already on Microsoft 365 |
| **Reliability** | ⭐⭐⭐⭐⭐ Microsoft operates it; no servers for you to break |
| **Linux support** | ⚠️ Improving but still second-class |

**Pros:** No infrastructure to maintain. Excellent MFA and conditional access. Massive integration ecosystem.

**Cons:** Subscription cost scales with users. Cloud dependency — no internet, no auth (though cached credentials help). Linux host management is weaker than IPA's. Vendor lock-in.

#### Active Directory + SSSD

| | |
|---|---|
| **Best for** | Windows-heavy shops with some Linux |
| **Reliability** | ⭐⭐⭐⭐ Extremely mature |
| **Linux support** | ⭐⭐⭐ Works well via SSSD, but Linux-specific policy is limited |

**Pros:** One directory for everything. Decades of operational knowledge available. Well-understood failure modes.

**Cons:** Windows Server licensing. Linux-specific features (sudo rules, HBAC, automount) require schema extensions or a separate tool. Certificate management is a separate role.

**The pragmatic middle path:** run **IPA with an AD trust**. AD stays authoritative for identity; IPA handles Linux-specific policy. You get both, at the cost of running both.

#### Keycloak

| | |
|---|---|
| **Best for** | Web application SSO (OIDC/SAML) |
| **Reliability** | ⭐⭐⭐⭐ Stable once configured |
| **Linux host support** | ❌ Not its job |

Keycloak is an *identity provider for applications*. It does not manage Linux logins, sudo rules, or host certificates. It's not a FreeIPA replacement — it's a complement. Keycloak federates with LDAP, AD, FreeIPA, and Kerberos, so a very common architecture is **FreeIPA for hosts + Keycloak for web apps**.

**Cons:** Complex server deployment, steep learning curve, and documentation that's often incomplete or outdated. Heavier to run and needs careful tuning.

#### Authentik

| | |
|---|---|
| **Best for** | Small-to-medium self-hosted SSO |
| **Reliability** | ⭐⭐⭐⭐ Good, actively developed |
| **Linux host support** | ⚠️ Recently added |

Authentik requires less initial configuration than Keycloak for teams without dedicated identity expertise. It covers SSO, LDAP, OAuth2/OIDC, SAML, SCIM, and forward authentication.

Recent development has moved toward the host-management space FreeIPA occupies: version 2025.12 added endpoint device management for Windows, macOS, and Linux, WebAuthn conditional UI, and an RBAC overhaul. Version 2026.2 added Linux PAM support for local device login, a WS-Federation provider, and a fleet connector for conditional access.

**Cons:** Flexible but can be complex, especially when custom flows need Python scripting. No Kerberos realm. No built-in PKI with FreeIPA's depth — Authentik can integrate with an external CA but doesn't match native Dogtag integration.

#### Zitadel

| | |
|---|---|
| **Best for** | Multi-tenant SaaS, contractor/external user scenarios |
| **Reliability** | ⭐⭐⭐⭐ Modern architecture, event-sourced |
| **Linux host support** | ❌ |

Zitadel's multi-tenancy model is notably clean for cases where external organizations need isolated identity pools without merging into your main directory.

#### Kanidm

| | |
|---|---|
| **Best for** | Modern Linux environments wanting simplicity |
| **Reliability** | ⭐⭐⭐⭐ Written in Rust, memory-safe by design |
| **Linux host support** | ⭐⭐⭐⭐ Has its own PAM/NSS modules |

Kanidm is the most interesting FreeIPA alternative for pure-Linux shops. It's dramatically simpler — a single binary instead of nine services — with strong passkey/WebAuthn support and built-in replication.

**Cons:** Much smaller ecosystem. No Kerberos. No AD trust. Fewer people have run it at scale. If you need AD interop, it's not an option.

#### LLDAP

| | |
|---|---|
| **Best for** | Home labs and very small teams |
| **Reliability** | ⭐⭐⭐⭐ Simple things break less |

A minimal LDAP server with a friendly UI. No Kerberos, no PKI, no policy engine. But if all you need is "a place to keep users that other apps can query," it's honest about being exactly that — and it will never wake you at 3 AM with an expired subsystem certificate.

### Side-by-side

| | FreeIPA | AD | Entra ID | Keycloak | Authentik | Kanidm |
|---|---|---|---|---|---|---|
| Linux host login | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ | ⭐⭐ | ❌ | ⭐⭐ | ⭐⭐⭐⭐ |
| Windows host login | ❌ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ❌ | ⭐⭐ | ❌ |
| Web app SSO | ⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ |
| Kerberos | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⚠️ | ⚠️ federate | ❌ | ❌ |
| Built-in CA/PKI | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐ | ❌ | ⭐⭐ | ⭐⭐ |
| Sudo/HBAC policy | ⭐⭐⭐⭐⭐ | ⭐⭐ | ⭐ | ❌ | ⭐⭐ | ⭐⭐⭐ |
| Passkeys/FIDO2 | ⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ |
| Operational simplicity | ⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ |
| Cost | Free | License | Subscription | Free | Free | Free |

### Decision guide

```
Do you need Linux host login with sudo/HBAC policy?
├─ NO → Do you need web app SSO only?
│        ├─ YES, simple → Authentik or Zitadel
│        └─ YES, enterprise → Keycloak or Entra ID
│
└─ YES → Do you need Active Directory interoperability?
         ├─ YES → FreeIPA with AD trust (no real alternative)
         │
         └─ NO → Do you need Kerberos SSO or a built-in CA?
                  ├─ YES → FreeIPA (still no real alternative)
                  └─ NO  → Kanidm (much simpler to operate)
```

### The most reliable configuration is usually hybrid

For most medium-to-large organizations in 2026:

```
Active Directory or Entra ID  ← authoritative identity source
           ↓ cross-forest trust
      FreeIPA / IdM           ← Linux hosts, sudo, HBAC, host certs
           ↓ LDAP federation
        Keycloak              ← web application SSO
```

Each system does what it's best at. Yes, it's three systems — but each one is simpler and more reliable in its own lane than one system stretched to cover all three.

### If you're staying with FreeIPA (most people should)

You get the biggest reliability win from these four things, in order:

1. **Run at least 3 replicas** in a mesh topology. Most outages become non-events.
2. **Monitor certificate expiry.** This single item prevents the most severe class of outage.
3. **Run `ipa-healthcheck` weekly** and act on failures.
4. **Test your restore procedure quarterly.**

Do those four and FreeIPA is a genuinely reliable system. Skip them and it will eventually hurt.

---

## 11. Best Practices Checklist

### At install time

- [ ] Static IP address, never DHCP
- [ ] FQDN hostname (three parts minimum)
- [ ] Forward *and* reverse DNS both resolve
- [ ] chrony configured and synced before installing
- [ ] `/var` on its own filesystem, 50 GB+
- [ ] Use a subdomain for the realm (`ipa.example.com`, not `example.com`)
- [ ] Never reuse an existing AD domain name
- [ ] Record the Directory Manager password in your password manager
- [ ] Let IPA manage DNS unless you have a strong reason not to

### Architecture

- [ ] Minimum 3 replicas in production
- [ ] Every replica has ≥2 replication agreements, ≤4
- [ ] At least 2 replicas run a CA (`--setup-ca`)
- [ ] Replicas in separate failure domains (racks, AZs, sites)
- [ ] One designated write-target for automation

### Ongoing operations

- [ ] `ipa-healthcheck` runs weekly, results reviewed
- [ ] Certificate expiry monitored with a 60-day warning
- [ ] `ipa-backup` daily, shipped off-box
- [ ] Restore tested quarterly on an isolated VM
- [ ] Log rotation configured *inside* 389-ds
- [ ] Watchdog timer active on every server
- [ ] Upgrades tested in staging first
- [ ] One replica at a time during any maintenance
- [ ] `ipa server-del` before decommissioning, never just delete the VM

### Security

- [ ] `allow_all` HBAC rule replaced with specific rules
- [ ] Password policy configured (`ipa pwpolicy-mod`)
- [ ] 2FA enabled for administrative accounts
- [ ] Directory Manager password used only for emergencies
- [ ] SELinux enforcing (fix contexts, don't disable)
- [ ] Firewall restricts LDAP/Kerberos to trusted networks
- [ ] Regular review of `ipa group-show admins`

### Things that will hurt you

- ❌ Running one IPA server
- ❌ Ignoring certificate expiry warnings
- ❌ Disabling SELinux to "fix" a problem
- ❌ `kill -9` on `ns-slapd`
- ❌ Deleting a replica VM without `ipa server-del`
- ❌ Running `re-initialize` without knowing which side has correct data
- ❌ Changing a server's hostname or IP after installation
- ❌ Automating anything destructive

---

## 12. Command Cheat Sheet

```bash
### Service control
ipactl start|stop|restart|status
systemctl status dirsrv@REALM httpd krb5kdc named pki-tomcatd

### Kerberos
kinit admin                  # get ticket
kinit -k -t /etc/krb5.keytab host/$(hostname -f)   # host ticket
klist                        # list tickets
klist -kt /etc/krb5.keytab   # list keytab entries
kdestroy                     # discard tickets
kvno host/server.example.com # test service ticket

### Users and groups
ipa user-add jdoe --first=John --last=Doe --password
ipa user-mod jdoe --shell=/bin/bash
ipa user-disable jdoe
ipa user-del jdoe
ipa passwd jdoe
ipa group-add-member devs --users=jdoe
ipa user-find --sizelimit=10

### Hosts
ipa host-add web1.example.com --ip-address=10.0.0.5
ipa host-del web1.example.com --updatedns
ipa hostgroup-add-member webservers --hosts=web1.example.com

### Access control
ipa hbacrule-add allow_devs
ipa hbacrule-add-user allow_devs --groups=developers
ipa hbacrule-add-host allow_devs --hostgroups=webservers
ipa hbactest --user=jdoe --host=web1.example.com --service=sshd
ipa sudorule-add devs_sudo
ipa sudorule-add-allow-command devs_sudo --sudocmds="/usr/bin/systemctl"

### DNS
ipa dnszone-find
ipa dnsrecord-add example.com www --a-rec=10.0.0.10
ipa dns-update-system-records
dig +short -t SRV _kerberos._tcp.example.com

### Certificates
getcert list
getcert list -i REQUEST_ID
ipa-cert-fix
ipa-certupdate
ipa-certupdate --force-server ipa1.example.com   # 4.13.1+
ipa cert-find --subject=web1.example.com

### Replication
ipa server-find
ipa topologysegment-find domain
ipa topologysuffix-verify domain
ipa-replica-manage list -v $(hostname -f)
ipa-replica-manage list-ruv
ipa-replica-manage clean-ruv REPLICA_ID
ipa-replica-manage re-initialize --from=ipa1.example.com   # ⚠️ DESTRUCTIVE

### Health and troubleshooting
ipa-healthcheck --failures-only
ipa-healthcheck --output-type json --output-file /tmp/hc.json
sss_cache -E
sssctl debug-level 9
sssctl user-checks jdoe
sssctl domain-status example.com

### Backup and restore
ipa-backup
ipa-backup --data --online
ipa-restore /var/lib/ipa/backup/ipa-full-YYYY-MM-DD-HH-MM-SS

### Client
ipa-client-install --mkhomedir --principal admin
ipa-client-install --uninstall
ipa-client-automount
```

---

## 13. Glossary

| Term | Plain English |
|---|---|
| **CA** | Certificate Authority — issues digital ID cards for computers and services |
| **CSN** | Change Sequence Number — timestamp used to decide which edit wins in replication |
| **Dogtag** | The Java program inside IPA that runs the certificate authority |
| **FQDN** | Fully Qualified Domain Name — the complete name, e.g. `web1.lab.example.com` |
| **HBAC** | Host-Based Access Control — rules for which users can log into which machines |
| **IdM** | Red Hat's supported, paid version of FreeIPA |
| **KDC** | Key Distribution Center — the Kerberos server that hands out tickets |
| **Kerberos** | An authentication system using time-limited tickets instead of repeated passwords |
| **Keytab** | A file holding a machine's secret key, so it can authenticate without a human |
| **LDAP** | Lightweight Directory Access Protocol — the language used to query the directory |
| **LMDB** | The newer database engine 389-ds uses in RHEL 10+ |
| **Principal** | A Kerberos identity, like `jsmith@LAB.EXAMPLE.COM` or `host/web1.lab.example.com` |
| **Realm** | The Kerberos domain name, always written in CAPITALS |
| **Replica** | An additional IPA server that stays in sync with the others |
| **RUV** | Replica Update Vector — a record of what each server has seen; leftovers cause problems |
| **SID** | Security Identifier — a Windows-style unique ID, used for AD compatibility |
| **SRV record** | A DNS entry that says "the Kerberos server is over here" |
| **SSSD** | The client-side program that talks to IPA and caches the answers |
| **TGT** | Ticket Granting Ticket — the master ticket you get when you first authenticate |
| **389-ds** | The LDAP database at the center of IPA. Named after LDAP's port number, 389 |

---

## Where to go next

- **Official docs:** https://www.freeipa.org/page/Documentation
- **Troubleshooting:** https://www.freeipa.org/page/Troubleshooting
- **Red Hat IdM docs:** https://access.redhat.com/articles/1586893
- **Ansible collection:** https://github.com/freeipa/ansible-freeipa
- **Mailing list:** freeipa-users@lists.fedorahosted.org
- **IRC:** #freeipa on libera.chat

---

*Guide current as of July 2026. FreeIPA 4.13.2 is the current stable release. Verify version-specific details against your distribution's packages, since distributions ship different versions.*
