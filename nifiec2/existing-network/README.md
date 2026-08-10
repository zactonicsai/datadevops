# Deploying Into an Existing Network

For the common enterprise case: **the network already exists and you do not
own it.** A platform or network team gave you a VPC, some private subnets,
and a Route 53 hosted zone. Your job is to put NiFi in it without creating
anything public and without touching their network.

---

## 1. What this mode does and does not do

| Does **not** create | Creates |
| --- | --- |
| VPC | A security group, inside the existing VPC |
| Subnets | An IAM role + instance profile (skippable) |
| Internet gateway | One EC2 instance, **private address only** |
| Route tables | One DNS record in the existing hosted zone |
| NAT gateway | |
| Public IPs or Elastic IPs | |
| The hosted zone itself | |

People reach NiFi by its **DNS name**, resolved by the hosted zone, over
your corporate network — VPN, Direct Connect, or from inside the VPC. There
is no path from the public internet at all.

```
   your laptop, on the VPN
          |
          |  looks up  nifi.internal.example.com
          v
   [Route 53 private hosted zone]  --> 10.20.11.47
          |
          |  https, over the corporate network
          v
   +---------------- existing VPC (not ours) ---------------+
   |   existing private subnet (not ours)                    |
   |      +-------------------------------+                  |
   |      | EC2: NiFi, private IP only    |  <- we create    |
   |      | security group                |  <- we create    |
   |      +-------------------------------+                  |
   |   no internet gateway, no public IP                     |
   +---------------------------------------------------------+
```

Everything adopted is flagged `ADOPTED_*` in `.existing-state`. The teardown
reads those flags and refuses to delete any of it.

---

## 2. What to ask your network team

Send this list. Nothing here is secret.

| # | Ask for | Example | Why |
| --- | --- | --- | --- |
| 1 | The VPC id | `vpc-0a1b2c3d` | Where everything goes |
| 2 | Which subnets you may use | `subnet-0aaa subnet-0bbb` | Two, in different zones, if possible |
| 3 | Are those subnets private? | yes | They should have no internet gateway route |
| 4 | Is there a **NAT gateway**? | yes / no | Decides how NiFi gets downloaded — see section 4 |
| 5 | Are there **VPC endpoints** for `s3`, `ssm`, `ssmmessages`, `ec2messages`? | list | Without NAT, these are how the instance installs anything and how you get a shell |
| 6 | The hosted zone id or name | `Z0123…` / `internal.example.com` | Where the DNS record goes |
| 7 | Is that zone **private**, and associated with this VPC? | yes | A private zone not associated with the VPC resolves nowhere |
| 8 | Which name may you create? | `nifi.internal.example.com` | Some teams reserve naming |
| 9 | Which internal ranges should reach NiFi? | `10.0.0.0/8`, VPN pool | Becomes the security group rule |
| 10 | May you create IAM roles? | yes / no | If not, ask for an instance profile with `AmazonSSMManagedInstanceCore` |

---

## 3. Step by step

### Step 1 — Fill in the config

```bash
cd nifi-ec2/existing-network
nano 00-existing-config.sh
```

The five that matter:

```bash
export EXISTING_VPC_ID="vpc-0a1b2c3d"
export EXISTING_SUBNET_IDS="subnet-0aaa subnet-0bbb"
export HOSTED_ZONE_NAME="internal.example.com"     # or HOSTED_ZONE_ID
export NIFI_DNS_NAME="nifi.internal.example.com"
export ALLOWED_CIDRS="10.0.0.0/8"
```

Also change `NIFI_PASSWORD` in `../scripts/00-config.sh` — this mode inherits
NiFi's version and credentials from there.

Don't know the subnet ids? Look them up by tag instead:

```bash
export SUBNET_TAG_KEY="Tier"
export SUBNET_TAG_VALUE="private"
```

### Step 2 — Look before you leap

```bash
./01-discover.sh
```

**Creates nothing.** It reads the network you were given and tells you what
is really there:

- the VPC, its CIDR, and whether DNS support is on
- each subnet: zone, free addresses, and **which route table governs it and
  where its default route goes** — internet gateway, NAT, transit gateway, or
  nowhere
- NAT gateways and VPC endpoints in the VPC
- the hosted zone: private or public, which VPCs it is associated with,
  whether your chosen name fits inside it, and whether a record already exists
- whether your credentials can actually create a security group and an instance

Read every line. It exits non-zero on anything that would block the build.

### Step 3 — Adopt the network

```bash
./02-adopt.sh
```

Records the VPC, subnets and zone as **adopted**, then creates the only two
things this mode adds: a security group and (unless you supplied one) an IAM
role. It prints a summary separating what is adopted from what is ours.

### Step 4 — Launch

```bash
./03-launch-private.sh
```

- launches with `--no-associate-public-ip-address`
- waits for a private address
- **saves any DNS record that already existed**, then UPSERTs
  `nifi.internal.example.com` → the private IP
- waits for Route 53 to report the change `INSYNC`

### Step 5 — Check it

```bash
./04-verify.sh --follow
```

It polls NiFi *from inside the VPC* through SSM, because your laptop probably
cannot reach it. Then it reports on both sides of DNS: what Route 53 holds,
whether it matches the instance, whether the name resolves from your machine,
and whether it resolves from inside the VPC.

Not on the VPN? Tunnel in:

```bash
./04-verify.sh --tunnel
# then browse https://localhost:8443/nifi
```

### Step 6 — Remove it

```bash
./99-teardown-adopted.sh --dry-run
./99-teardown-adopted.sh
```

Deletes the DNS record (or restores the value that was there before), the
instance, the security group, and the IAM role if it created one. **The VPC,
subnets, route tables, gateways and hosted zone are never touched.**

---

## 4. The download problem

The bootstrap needs about 1.2 GB of NiFi plus some OS packages. A properly
private subnet has no route to the internet, so decide where they come from.

### If there is a NAT gateway

```bash
export NIFI_SOURCE_MODE="internet"
```

Nothing else to do. `01-discover.sh` will confirm it found one.

### If there is no NAT

You need an **S3 gateway VPC endpoint** — which many private VPCs already
have, because the Amazon Linux package repositories are served from S3.
Put the NiFi zip in a bucket you control:

```bash
aws s3 cp nifi-1.28.1-bin.zip        s3://my-artifacts-bucket/nifi/
aws s3 cp nifi-1.28.1-bin.zip.sha512 s3://my-artifacts-bucket/nifi/
```

```bash
export NIFI_SOURCE_MODE="s3"
export NIFI_S3_PREFIX="s3://my-artifacts-bucket/nifi"
```

`02-adopt.sh` then adds a small inline policy to the role granting
`s3:GetObject` on that bucket and nothing else. The checksum is still
verified — copying through S3 does not remove the need to check what you got.

| Have | Set `NIFI_SOURCE_MODE` to | Also need |
| --- | --- | --- |
| NAT gateway | `internet` | nothing |
| S3 gateway endpoint only | `s3` | the zip in your bucket |
| Neither | — | ask for one; the instance cannot install anything |

For **SSM** — the shell, the tunnel, the verify script — you need either the
NAT route or three interface endpoints: `ssm`, `ssmmessages`, `ec2messages`.
`01-discover.sh` checks and tells you which are missing.

---

## 5. Certificates and the DNS name

Left alone, NiFi generates a self-signed certificate naming the machine's own
hostname, like `ip-10-20-11-47.ec2.internal`. Browsing to
`nifi.internal.example.com` then produces *two* complaints: untrusted issuer
**and** wrong name.

`GENERATE_CERT_FOR_DNS="true"` (the default here) generates the certificate
during bootstrap with the DNS name inside it:

```
CN  = nifi.internal.example.com
SAN = DNS:nifi.internal.example.com, DNS:<internal hostname>,
      DNS:localhost, IP:<private ip>
```

Still self-signed, so still one warning — but an honest one, about the issuer
rather than the name. The public half is left at
`/opt/nifi/nifi-public-cert.pem` so you can distribute it to browsers or to
an internal trust store.

**Better, when you can:** ask for a certificate from your corporate CA with
the same names, and drop it into `conf/keystore.p12`. Then the warning goes
away entirely, because your machines already trust that CA.

---

## 6. What changes when the instance is replaced

A private IP survives a stop and start, unlike a public one. It does change
if the instance is rebuilt or moved.

```bash
./05-dns-sync.sh              # re-point the record at the current instance
./05-dns-sync.sh i-0newid     # or at a specific one
```

It updates Route 53 **and** refreshes `nifi.web.proxy.host` on the instance,
then restarts NiFi. Both are needed: DNS sends people to the right machine,
and `proxy.host` is what makes NiFi accept the request when they get there.

---

## 7. Adding Keycloak in this mode

The `../keycloak` scripts assume the public build. To use them here:

1. Launch Keycloak with the same pattern — private subnet, no public IP.
2. Give it its own record in the same zone, `sso.internal.example.com`.
3. Use that DNS name everywhere instead of the `nip.io` trick. It is what
   nip.io was standing in for, and a real internal zone is strictly better.
4. The `/etc/hosts` line on the NiFi box becomes unnecessary — the hosted
   zone already resolves the name to a private address for everyone.

That last point is worth noticing: the awkward part of the public build
exists only because there was no internal DNS. With a hosted zone, it
disappears.

---

## 8. Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| Bootstrap hangs at the download | No route out, and `NIFI_SOURCE_MODE=internet` | Switch to `s3`, or ask for NAT |
| `04-verify.sh` reports SSM not answering | No NAT and no SSM interface endpoints | Ask for `ssm`, `ssmmessages`, `ec2messages` |
| Name resolves nowhere inside the VPC | Private zone not associated with this VPC | Ask the DNS team to associate it |
| Name resolves for you but not colleagues | Split-horizon DNS, or they are off the VPN | Expected — this is a private name |
| Browser says the certificate name is wrong | `GENERATE_CERT_FOR_DNS` was false | Set it true and rebuild, or install a CA-signed certificate |
| `Invalid parameter` / blank page after login | `nifi.web.proxy.host` missing the DNS name | `./05-dns-sync.sh` rewrites it |
| A public IP was assigned anyway | The subnet forces `MapPublicIpOnLaunch` | The launch script warns; ask your network team, or accept it |
| Record already existed | Somebody else uses that name | It is saved to `build/previous-record.json` and restored on teardown |
| Cannot create a security group | Missing `ec2:CreateSecurityGroup` | `01-discover.sh` catches this before you start |

---

## 9. Files

| File | Does |
| --- | --- |
| `00-existing-config.sh` | All settings. The only file you edit |
| `01-discover.sh` | Read-only inventory and validation. Creates nothing |
| `02-adopt.sh` | Records the network; creates the security group and IAM role |
| `03-launch-private.sh` | Launches with no public IP; creates the DNS record |
| `04-verify.sh` | Status, logs, `--tunnel` for access from outside |
| `05-dns-sync.sh` | Re-points DNS after the address changes |
| `99-teardown-adopted.sh` | Removes only what we made |
| `user-data-private.sh.tmpl` | First-boot script: S3 or internet download, DNS-named certificate |
