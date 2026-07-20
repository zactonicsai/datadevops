# FreeIPA DNS → Route 53 Migration Runbook

**Every command, in order, with the gotchas that break it**

*Companion to the DNS Migration Plan. Current as of July 2026.*

---

## Table of Contents

1. [Read the Gotchas First](#1-read-the-gotchas-first)
2. [Prerequisites and IAM](#2-prerequisites-and-iam)
3. [Step 1: Export from FreeIPA](#3-step-1-export-from-freeipa)
4. [Step 2: Create the Hosted Zone](#4-step-2-create-the-hosted-zone)
5. [Step 3: Convert Records to Route 53 Format](#5-step-3-convert-records-to-route-53-format)
6. [Step 4: Import in Batches](#6-step-4-import-in-batches)
7. [Step 5: Reverse Zones](#7-step-5-reverse-zones)
8. [Step 6: Verify Before Cutover](#8-step-6-verify-before-cutover)
9. [Step 7: Resolver Cutover](#9-step-7-resolver-cutover)
10. [Step 8: Soak and Validate](#10-step-8-soak-and-validate)
11. [Step 9: Retire IPA DNS](#11-step-9-retire-ipa-dns)
12. [Rollback Commands](#12-rollback-commands)
13. [Full Command Reference](#13-full-command-reference)

---

## 1. Read the Gotchas First

These are the things that will cost you a day each if you discover them mid-migration.

### 🔴 Gotcha 1: SSHFP and TLSA are public-zone only

Route 53 supports SSHFP and TLSA record types **for public hosted zones only**. HTTPS and SVCB work in both public and private zones.

Your FreeIPA migration almost certainly targets a **private** hosted zone. If FreeIPA is serving SSHFP records (common — `ipa-client-install` can publish them), **they cannot be migrated to a private zone.**

```bash
# Check before you start
ldapsearch -Y GSSAPI -b "cn=dns,$(ipa env basedn | awk '{print $2}')" \
  "(objectclass=idnsrecord)" | grep -ci "sshfprecord"
```

**If that returns > 0**, your options are:
- Drop SSHFP records (most common — they need DNSSEC validation on the client anyway)
- Keep a small BIND server for those records
- Use a public hosted zone (usually inappropriate for internal names)

### 🔴 Gotcha 2: You cannot convert a public zone to private, or vice versa

You can't convert a public hosted zone to a private hosted zone or the other way around. You must create a new hosted zone with the same name and create new resource record sets.

**Decide private vs public before you create anything.** Getting this wrong means starting over.

### 🔴 Gotcha 3: The 1000-element and 32000-character batch limits

A `ChangeResourceRecordSets` request cannot contain more than **1,000 `ResourceRecord` elements** (including alias records). **When the action is `UPSERT`, each element counts twice.**

The sum of characters in all `Value` elements cannot exceed **32,000 characters**, and with `UPSERT` each character counts twice.

**Practical effect:** with `UPSERT` (which you want, for idempotency), your real limit is **500 records per batch**, and ~16,000 characters. The batching script in Step 4 handles this.

### 🔴 Gotcha 4: SRV and MX values must not be split

Covered in the DNS migration plan, repeated here because it silently destroys your zone:

`SRV` values have **four** space-separated fields (`priority weight port target`). `MX` has **two** (`priority target`). Any converter that splits on a fixed field count truncates these to the first number. The JSON stays valid, the API call succeeds, and every SRV record — the records clients use to find your KDC — becomes garbage.

**Always verify SRV values have 4 fields before applying.**

### 🟠 Gotcha 5: No LOC record support

Route 53's supported types are: `A | AAAA | CAA | CNAME | DS | HTTPS | MX | NAPTR | NS | PTR | SOA | SPF | SRV | SSHFP | SVCB | TLSA | TXT`.

**`LOC` is not supported.** If FreeIPA serves LOC records, they're lost. Check:

```bash
ldapsearch -Y GSSAPI -b "cn=dns,$(ipa env basedn | awk '{print $2}')" \
  "(objectclass=idnsrecord)" | grep -ci "locrecord"
```

### 🟠 Gotcha 6: No GSS-TSIG dynamic updates

Route 53 has no equivalent to Kerberos-authenticated `nsupdate`. If your clients self-register, that stops working. See §9 of the DNS Migration Plan for the three replacement options.

```bash
# Check whether any zone allows dynamic update
ipa dnszone-find --sizelimit=0 --all | grep -i "dynamic update"
```

### 🟠 Gotcha 7: TXT records need embedded quotes

A TXT record contains one or more strings **enclosed in double quotation marks**. A single string can include up to 255 characters; longer values must be split into multiple quoted strings.

FreeIPA stores the realm TXT record as bare `EXAMPLE.COM`. Route 53 needs `"EXAMPLE.COM"` — **with the quotes as part of the value**. The converter handles this; verify it did.

### 🟠 Gotcha 8: CNAME at the zone apex is forbidden

DNS itself forbids this, and Route 53 enforces it. Also: if you create a CNAME for a subdomain, **you cannot create any other records with that same name**. FreeIPA is more permissive in some edge cases; the import will reject these.

### 🟡 Gotcha 9: Private zones need `ec2:DescribeVpcs`

The `CreateHostedZone` request requires the caller to have `ec2:DescribeVpcs` permission. This is easy to miss in a tightly-scoped IAM policy.

### 🟡 Gotcha 10: Trailing dots are optional but be consistent

Route 53 treats `www.example.com` and `www.example.com.` as identical. Not a failure source, but inconsistency makes your diffs noisy.

### 🟡 Gotcha 11: DHCP option set changes are not immediate

Existing instances keep old DNS settings until their DHCP lease renews — typically hours. Plan for it, or force renewal.

### Gotcha summary table

| # | Gotcha | Check command | Severity |
|---|---|---|---|
| 1 | SSHFP/TLSA private-zone unsupported | `grep -c sshfprecord` | 🔴 |
| 2 | Public↔private not convertible | Decide upfront | 🔴 |
| 3 | 1000 elements / UPSERT counts double | Use batching script | 🔴 |
| 4 | SRV/MX field truncation | Verify 4 fields | 🔴 |
| 5 | LOC unsupported | `grep -c locrecord` | 🟠 |
| 6 | No GSS-TSIG | `ipa dnszone-find \| grep dynamic` | 🟠 |
| 7 | TXT needs literal quotes | Inspect converted JSON | 🟠 |
| 8 | CNAME apex / coexistence | Import errors reveal | 🟠 |
| 9 | Needs `ec2:DescribeVpcs` | IAM policy review | 🟡 |
| 10 | Trailing dot consistency | Cosmetic | 🟡 |
| 11 | DHCP lease delay | Expect hours | 🟡 |

---

## 2. Prerequisites and IAM

### Environment setup

```bash
# Set these once; every later command uses them
export AWS_REGION="us-east-1"
export VPC_ID="vpc-0abc123def456789"
export IPA_DOMAIN="example.com"
export IPA_REALM="EXAMPLE.COM"
export IPA_SERVER="ipa1.example.com"
export WORKDIR="$HOME/ipa-r53-migration"

mkdir -p "$WORKDIR"/{export,convert,batches,verify}
cd "$WORKDIR"

# Verify CLI and identity
aws --version
aws sts get-caller-identity
```

### IAM policy for the migration operator

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "Route53ZoneManagement",
      "Effect": "Allow",
      "Action": [
        "route53:CreateHostedZone",
        "route53:GetHostedZone",
        "route53:ListHostedZones",
        "route53:ListHostedZonesByName",
        "route53:ChangeResourceRecordSets",
        "route53:ListResourceRecordSets",
        "route53:GetChange",
        "route53:AssociateVPCWithHostedZone",
        "route53:CreateQueryLoggingConfig"
      ],
      "Resource": "*"
    },
    {
      "Sid": "RequiredForPrivateZones",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeVpcs",
        "ec2:DescribeDhcpOptions",
        "ec2:CreateDhcpOptions",
        "ec2:AssociateDhcpOptions"
      ],
      "Resource": "*"
    }
  ]
}
```

> **Note the `ec2:DescribeVpcs` entry** — Gotcha 9. Without it, `create-hosted-zone` fails with a confusing permissions error.

### Verify VPC DNS attributes

Both must be `true` or nothing resolves:

```bash
aws ec2 describe-vpc-attribute --vpc-id "$VPC_ID" \
  --attribute enableDnsSupport --query 'EnableDnsSupport.Value'
aws ec2 describe-vpc-attribute --vpc-id "$VPC_ID" \
  --attribute enableDnsHostnames --query 'EnableDnsHostnames.Value'

# Fix if either returns false
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames
```

### Pre-flight checklist

```bash
# Take a backup FIRST
ssh "$IPA_SERVER" 'sudo ipa-backup'

# Confirm current IPA DNS is healthy before changing anything
ssh "$IPA_SERVER" 'sudo ipactl status | grep -i named'
dig +short -t SRV "_kerberos._tcp.${IPA_DOMAIN}"
dig +short -t SRV "_ldap._tcp.${IPA_DOMAIN}"
```

- [ ] `ipa-backup` completed and verified
- [ ] Gotchas 1, 5, 6 checked against your zone
- [ ] Private vs public decided (Gotcha 2)
- [ ] IAM policy attached, `ec2:DescribeVpcs` present
- [ ] VPC DNS attributes both `true`
- [ ] Change window agreed
- [ ] Rollback runbook reviewed

---

## 3. Step 1: Export from FreeIPA

### 3.1 The system records (most important)

```bash
ssh "$IPA_SERVER" 'kinit admin && ipa dns-update-system-records --dry-run' \
  | tee "$WORKDIR/export/system-records.txt"
```

Expected output — these are how clients find your KDC:

```
_kerberos-master._tcp.example.com. 86400 IN SRV 0 100 88 ipa1.example.com.
_kerberos-master._udp.example.com. 86400 IN SRV 0 100 88 ipa1.example.com.
_kerberos._tcp.example.com.        86400 IN SRV 0 100 88 ipa1.example.com.
_kerberos._udp.example.com.        86400 IN SRV 0 100 88 ipa1.example.com.
_kpasswd._tcp.example.com.         86400 IN SRV 0 100 464 ipa1.example.com.
_kpasswd._udp.example.com.         86400 IN SRV 0 100 464 ipa1.example.com.
_ldap._tcp.example.com.            86400 IN SRV 0 100 389 ipa1.example.com.
_kerberos.example.com.             86400 IN TXT "EXAMPLE.COM"
ipa-ca.example.com.                86400 IN A   10.0.1.10
```

> **Don't lose the `ipa-ca` record.** It's used in all certificates issued by FreeIPA as the point to obtain certificate validation via OCSP or CRL. Missing it breaks certificate validation.

### 3.2 Full record dump

```bash
# Zone list
ssh "$IPA_SERVER" \
  'kinit admin && ipa dnszone-find --raw --sizelimit=0' \
  | awk '/idnsname:/ {print $2}' | sed 's/\.$//' \
  > "$WORKDIR/export/zone-list.txt"

cat "$WORKDIR/export/zone-list.txt"

# Raw LDAP dump — the authoritative source
ssh "$IPA_SERVER" 'BASEDN=$(kinit admin >/dev/null 2>&1; ipa env basedn | awk "{print \$2}"); \
  ldapsearch -Y GSSAPI -b "cn=dns,${BASEDN}" "(objectclass=idnsrecord)"' \
  > "$WORKDIR/export/raw-records.ldif"

wc -l "$WORKDIR/export/raw-records.ldif"
```

### 3.3 Record type census — checks Gotchas 1 and 5

```bash
cd "$WORKDIR/export"
echo "=== Record type census ==="
for t in arecord aaaarecord cnamerecord mxrecord srvrecord txtrecord \
         ptrrecord nsrecord sshfprecord tlsarecord caarecord \
         naptrrecord locrecord dnamerecord; do
  n=$(grep -ci "^${t}:" raw-records.ldif 2>/dev/null || echo 0)
  [ "$n" -gt 0 ] && printf '%-16s %s\n' "$t" "$n"
done

echo ""
echo "=== BLOCKERS ==="
S=$(grep -ci "^sshfprecord:" raw-records.ldif 2>/dev/null || echo 0)
L=$(grep -ci "^locrecord:"   raw-records.ldif 2>/dev/null || echo 0)
T=$(grep -ci "^tlsarecord:"  raw-records.ldif 2>/dev/null || echo 0)
[ "$S" -gt 0 ] && echo "SSHFP: $S records — NOT supported in private zones (Gotcha 1)"
[ "$L" -gt 0 ] && echo "LOC:   $L records — NOT supported at all (Gotcha 5)"
[ "$T" -gt 0 ] && echo "TLSA:  $T records — NOT supported in private zones (Gotcha 1)"
[ "$S" -eq 0 ] && [ "$L" -eq 0 ] && [ "$T" -eq 0 ] && echo "None. Safe to proceed."
```

**Stop here and resolve any blockers before continuing.**

### 3.4 Generate a zone file per zone

```bash
cat > "$WORKDIR/export-zone.sh" <<'SCRIPT'
#!/usr/bin/env bash
# export-zone.sh <zone> — dump one IPA zone as a BIND-style zone file
set -euo pipefail
ZONE="${1:?usage: $0 <zone>}"

kinit admin >/dev/null 2>&1 || true

echo "\$ORIGIN ${ZONE}."
echo "\$TTL 300"

ipa dnsrecord-find "$ZONE" --sizelimit=0 --all --raw 2>/dev/null | \
python3 -c '
import sys, re
name = None
for line in sys.stdin:
    line = line.rstrip("\n")
    m = re.match(r"\s*idnsname:\s*(\S+)", line)
    if m:
        name = m.group(1)
        continue
    m = re.match(r"\s*(\w+)record:\s*(.+)", line)
    if m and name:
        rtype = m.group(1).upper()
        val = m.group(2).strip()
        if rtype == "TXT" and not val.startswith("\""):
            val = "\"" + val + "\""
        print(f"{name}\tIN\t{rtype}\t{val}")
'
SCRIPT
chmod +x "$WORKDIR/export-zone.sh"

# Run it for every zone
scp "$WORKDIR/export-zone.sh" "$IPA_SERVER:/tmp/"
while read -r z; do
  [ -z "$z" ] && continue
  echo "Exporting $z ..."
  ssh "$IPA_SERVER" "bash /tmp/export-zone.sh '$z'" \
    > "$WORKDIR/export/${z}.zone"
  wc -l "$WORKDIR/export/${z}.zone"
done < "$WORKDIR/export/zone-list.txt"
```

### 3.5 Validate the exports

```bash
# If named-checkzone is available locally
while read -r z; do
  [ -z "$z" ] && continue
  named-checkzone "$z" "$WORKDIR/export/${z}.zone" 2>&1 | tail -2
done < "$WORKDIR/export/zone-list.txt"
```

> If `named-checkzone` rejects a file, **fix the export before importing**. Do not push a broken zone into Route 53.

---

## 4. Step 2: Create the Hosted Zone

### 4.1 Create a private hosted zone

```bash
aws route53 create-hosted-zone \
  --name "$IPA_DOMAIN" \
  --caller-reference "ipa-migration-$(date +%s)" \
  --vpc "VPCRegion=${AWS_REGION},VPCId=${VPC_ID}" \
  --hosted-zone-config "Comment=Migrated from FreeIPA,PrivateZone=true" \
  > "$WORKDIR/zone-created.json"

# Capture the zone ID — you need it for every later command
export ZONE_ID=$(python3 -c "
import json
d = json.load(open('$WORKDIR/zone-created.json'))
print(d['HostedZone']['Id'].split('/')[-1])
")
echo "ZONE_ID=$ZONE_ID"
echo "export ZONE_ID=$ZONE_ID" >> "$WORKDIR/env.sh"
```

> ⚠️ **Gotcha 2 reminder:** this decision is permanent. You cannot convert private → public later; you'd have to create a new zone and re-import everything.

### 4.2 Associate additional VPCs if needed

```bash
aws route53 associate-vpc-with-hosted-zone \
  --hosted-zone-id "$ZONE_ID" \
  --vpc "VPCRegion=us-west-2,VPCId=vpc-0def456"
```

### 4.3 Verify

```bash
aws route53 get-hosted-zone --id "$ZONE_ID" \
  --query '{Name:HostedZone.Name,Private:HostedZone.Config.PrivateZone,Records:HostedZone.ResourceRecordSetCount,VPCs:VPCs}'

# A fresh private zone starts with just NS and SOA
aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" \
  --query 'ResourceRecordSets[].[Name,Type]' --output table
```

---

## 5. Step 3: Convert Records to Route 53 Format

Save this as `$WORKDIR/zone2r53.py`. It handles every gotcha in Section 1 — batch limits, SRV/MX field preservation, TXT quoting, and unsupported record types.

```python
#!/usr/bin/env python3
"""
zone2r53.py — convert a BIND zone file into Route 53 change batches.

Usage:
    zone2r53.py <zonefile> <origin> <outdir> [--ttl 300]

Handles the Route 53 constraints that break naive converters:
  * 1000 ResourceRecord elements per batch; UPSERT counts each TWICE
    -> effective limit 500 records per batch
  * 32000 characters across all Value elements; UPSERT counts double
    -> effective limit ~16000 chars per batch
  * SRV/MX values must keep ALL space-separated fields
  * TXT values must be wrapped in literal double quotes
  * SOA/NS at apex are managed by Route 53 and must be skipped
  * SSHFP/TLSA/LOC are dropped for private zones (with a warning)
"""
import sys, json, os, collections

# Route 53 supported types (private hosted zones).
# SSHFP and TLSA are public-zone only. LOC is unsupported entirely.
PRIVATE_OK = {"A", "AAAA", "CAA", "CNAME", "DS", "HTTPS", "MX", "NAPTR",
              "NS", "PTR", "SPF", "SRV", "SVCB", "TXT"}
PUBLIC_ONLY = {"SSHFP", "TLSA"}
UNSUPPORTED = {"LOC"}

# Effective per-batch limits with UPSERT (each element/char counts twice)
MAX_RECORDS_PER_BATCH = 500
MAX_CHARS_PER_BATCH = 16000


def parse_zone(path, origin):
    recs = collections.defaultdict(list)
    skipped = collections.Counter()
    origin = origin.rstrip(".") + "."

    for raw in open(path):
        line = raw.split(";", 1)[0].strip()
        if not line or line.startswith("$"):
            continue
        parts = line.split()
        if len(parts) < 4:
            continue
        name, cls, rtype = parts[0], parts[1].upper(), parts[2].upper()
        if cls != "IN":
            continue

        # Route 53 manages SOA and apex NS itself
        if rtype == "SOA":
            skipped["SOA (managed by Route53)"] += 1
            continue

        # CRITICAL: keep every remaining field.
        # SRV = "prio weight port target", MX = "prio target".
        value = " ".join(parts[3:])

        if rtype in UNSUPPORTED:
            skipped[f"{rtype} (unsupported by Route53)"] += 1
            continue
        if rtype in PUBLIC_ONLY:
            skipped[f"{rtype} (public zones only)"] += 1
            continue
        if rtype not in PRIVATE_OK:
            skipped[f"{rtype} (unknown type)"] += 1
            continue

        # FQDN normalisation
        if name in ("@", origin):
            fqdn = origin
        elif name.endswith("."):
            fqdn = name
        else:
            fqdn = f"{name}.{origin}"

        # Apex NS is Route53's own delegation set — never overwrite it
        if rtype == "NS" and fqdn == origin:
            skipped["apex NS (managed by Route53)"] += 1
            continue

        # TXT must be quoted
        if rtype == "TXT" and not value.startswith('"'):
            value = '"' + value.replace('"', '\\"') + '"'

        recs[(fqdn, rtype)].append(value)

    return recs, skipped


def validate(recs):
    """Catch the truncation bug and other structural problems."""
    errors = []
    for (fqdn, rtype), values in recs.items():
        for v in values:
            n = len(v.split())
            if rtype == "SRV" and n != 4:
                errors.append(
                    f"SRV {fqdn} has {n} fields (need 4): {v!r} "
                    "— TRUNCATION BUG")
            if rtype == "MX" and n != 2:
                errors.append(
                    f"MX {fqdn} has {n} fields (need 2): {v!r} "
                    "— TRUNCATION BUG")
            if rtype == "TXT" and not v.startswith('"'):
                errors.append(f"TXT {fqdn} not quoted: {v!r}")
            if len(v) > 4000:
                errors.append(f"{rtype} {fqdn} value exceeds 4000 chars")
        if rtype == "CNAME" and len(values) > 1:
            errors.append(f"CNAME {fqdn} has {len(values)} values (max 1)")
    return errors


def build_batches(recs, ttl):
    batches, current = [], []
    n_recs = n_chars = 0

    for (fqdn, rtype), values in sorted(recs.items()):
        rrs = {
            "Action": "UPSERT",
            "ResourceRecordSet": {
                "Name": fqdn,
                "Type": rtype,
                "TTL": ttl,
                "ResourceRecords": [{"Value": v} for v in values],
            },
        }
        c = sum(len(v) for v in values)
        r = len(values)

        if current and (n_recs + r > MAX_RECORDS_PER_BATCH
                        or n_chars + c > MAX_CHARS_PER_BATCH):
            batches.append(current)
            current, n_recs, n_chars = [], 0, 0

        current.append(rrs)
        n_recs += r
        n_chars += c

    if current:
        batches.append(current)
    return batches


def main():
    if len(sys.argv) < 4:
        print(__doc__)
        sys.exit(1)
    zonefile, origin, outdir = sys.argv[1], sys.argv[2], sys.argv[3]
    ttl = 300
    if "--ttl" in sys.argv:
        ttl = int(sys.argv[sys.argv.index("--ttl") + 1])

    os.makedirs(outdir, exist_ok=True)
    recs, skipped = parse_zone(zonefile, origin)

    errors = validate(recs)
    if errors:
        print("VALIDATION FAILED:", file=sys.stderr)
        for e in errors:
            print(f"  {e}", file=sys.stderr)
        sys.exit(2)

    batches = build_batches(recs, ttl)
    for i, b in enumerate(batches, 1):
        path = os.path.join(outdir, f"batch-{i:03d}.json")
        with open(path, "w") as f:
            json.dump({"Comment": f"FreeIPA migration batch {i}",
                       "Changes": b}, f, indent=2)
        n = sum(len(c["ResourceRecordSet"]["ResourceRecords"]) for c in b)
        print(f"  {path}  ({len(b)} rrsets, {n} records)")

    total = sum(len(v) for v in recs.values())
    print(f"\nTotal: {len(recs)} rrsets / {total} records "
          f"in {len(batches)} batch(es)")
    if skipped:
        print("\nSkipped:")
        for k, v in skipped.items():
            print(f"  {k}: {v}")


if __name__ == "__main__":
    main()
```

### 5.1 Run the conversion

```bash
cd "$WORKDIR"
chmod +x zone2r53.py

while read -r z; do
  [ -z "$z" ] && continue
  echo "=== Converting $z ==="
  ./zone2r53.py "export/${z}.zone" "$z" "batches/${z}" --ttl 300
done < export/zone-list.txt
```

Expected output:

```
=== Converting example.com ===
  batches/example.com/batch-001.json  (13 rrsets, 15 records)

Total: 13 rrsets / 15 records in 1 batch(es)

Skipped:
  SOA (managed by Route53): 1
  apex NS (managed by Route53): 1
```

> **If it exits with code 2**, validation failed. Read the errors — a `TRUNCATION BUG` message means your source zone file is malformed. Fix the export, don't bypass the check.

### 5.2 Inspect before importing — never skip this

```bash
# Show every SRV record and confirm it has 4 fields
python3 - "$WORKDIR/batches/${IPA_DOMAIN}"/batch-*.json <<'PYSCRIPT'
import json, sys
bad = 0
for path in sys.argv[1:]:
    d = json.load(open(path))
    for c in d["Changes"]:
        r = c["ResourceRecordSet"]
        if r["Type"] not in ("SRV", "MX", "TXT"):
            continue
        for v in r["ResourceRecords"]:
            val = v["Value"]
            n = len(val.split())
            flag = ""
            if r["Type"] == "SRV" and n != 4:
                flag = "  <<< BAD"; bad += 1
            if r["Type"] == "MX" and n != 2:
                flag = "  <<< BAD"; bad += 1
            if r["Type"] == "TXT" and not val.startswith('"'):
                flag = "  <<< UNQUOTED"; bad += 1
            print(f"{r['Name']:34} {r['Type']:5} {val!r}{flag}")
print(f"\nProblems: {bad}")
sys.exit(1 if bad else 0)
PYSCRIPT
```

**All SRV values must look like `'0 100 88 ipa1.example.com.'` — four fields.**

---

## 6. Step 4: Import in Batches

### 6.1 Apply with change tracking

```bash
cat > "$WORKDIR/apply-batches.sh" <<'SCRIPT'
#!/usr/bin/env bash
# apply-batches.sh <zone-id> <batch-dir>
set -euo pipefail
ZONE_ID="${1:?zone id}"
BATCH_DIR="${2:?batch dir}"

for f in "$BATCH_DIR"/batch-*.json; do
  echo "=== Applying $(basename "$f") ==="
  CHANGE_ID=$(aws route53 change-resource-record-sets \
    --hosted-zone-id "$ZONE_ID" \
    --change-batch "file://$f" \
    --query 'ChangeInfo.Id' --output text)

  echo "  Change ID: $CHANGE_ID"
  echo -n "  Waiting for INSYNC"
  aws route53 wait resource-record-sets-changed --id "$CHANGE_ID"
  echo " done"
done
echo "All batches applied."
SCRIPT
chmod +x "$WORKDIR/apply-batches.sh"

"$WORKDIR/apply-batches.sh" "$ZONE_ID" "$WORKDIR/batches/$IPA_DOMAIN"
```

> **`aws route53 wait resource-record-sets-changed` blocks until the change reaches `INSYNC`.** Use it — applying batches faster than propagation causes confusing partial states.

### 6.2 If a batch fails

Route 53 change batches are **atomic**: if validation fails for any change, the entire request is cancelled and nothing is applied.

```bash
# Common errors and causes:
#   InvalidChangeBatch: RRSet with DNS name X is not permitted in zone Y
#     -> record name outside the zone; check FQDN normalisation
#   InvalidChangeBatch: RRSet of type CNAME with DNS name X is not permitted
#     -> CNAME at apex, or CNAME coexisting with another type (Gotcha 8)
#   InvalidChangeBatch: Invalid Resource Record: FATAL problem: ...
#     -> malformed value; usually SRV/MX truncation (Gotcha 4)
#   InvalidChangeBatch: number of records exceeds limit
#     -> batch too large; reduce MAX_RECORDS_PER_BATCH (Gotcha 3)

# Retry a single batch after fixing
aws route53 change-resource-record-sets \
  --hosted-zone-id "$ZONE_ID" \
  --change-batch "file://$WORKDIR/batches/$IPA_DOMAIN/batch-003.json"
```

### 6.3 Confirm the record count

```bash
aws route53 get-hosted-zone --id "$ZONE_ID" \
  --query 'HostedZone.ResourceRecordSetCount'

# Full listing
aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" \
  --output json > "$WORKDIR/verify/r53-records.json"

python3 -c "
import json
d = json.load(open('$WORKDIR/verify/r53-records.json'))
for r in d['ResourceRecordSets']:
    vals = [v['Value'] for v in r.get('ResourceRecords', [])]
    print(f\"{r['Name']:36} {r['Type']:6} {vals}\")
"
```

---

## 7. Step 5: Reverse Zones

**The most commonly forgotten step.** If PTR sync was enabled in FreeIPA, you have reverse zones with real records.

### 7.1 Identify reverse zones

```bash
grep -E "in-addr\.arpa|ip6\.arpa" "$WORKDIR/export/zone-list.txt"
```

### 7.2 Create the reverse hosted zone

Route 53 reverse zones use the standard `in-addr.arpa` naming:

```bash
# For 10.0.1.0/24
export REV_ZONE="1.0.10.in-addr.arpa"

aws route53 create-hosted-zone \
  --name "$REV_ZONE" \
  --caller-reference "ipa-rev-$(date +%s)" \
  --vpc "VPCRegion=${AWS_REGION},VPCId=${VPC_ID}" \
  --hosted-zone-config "Comment=Reverse zone migrated from FreeIPA,PrivateZone=true" \
  > "$WORKDIR/rev-zone-created.json"

export REV_ZONE_ID=$(python3 -c "
import json
print(json.load(open('$WORKDIR/rev-zone-created.json'))['HostedZone']['Id'].split('/')[-1])
")
echo "REV_ZONE_ID=$REV_ZONE_ID"
```

### 7.3 Convert and apply

```bash
./zone2r53.py "export/${REV_ZONE}.zone" "$REV_ZONE" "batches/${REV_ZONE}" --ttl 300
"$WORKDIR/apply-batches.sh" "$REV_ZONE_ID" "$WORKDIR/batches/$REV_ZONE"
```

### 7.4 Verify PTR records

```bash
aws route53 list-resource-record-sets --hosted-zone-id "$REV_ZONE_ID" \
  --query "ResourceRecordSets[?Type=='PTR'].[Name,ResourceRecords[0].Value]" \
  --output table
```

> **Reverse DNS matters more than people expect in Kerberos environments.** Missing PTR records cause intermittent authentication problems that are very hard to diagnose.

---

## 8. Step 6: Verify Before Cutover

**Nothing is using Route 53 yet. This is your last safe checkpoint.**

### 8.1 Query Route 53 directly

Private hosted zones only answer from inside the VPC. Run this **on an EC2 instance in the associated VPC**:

```bash
# The VPC resolver is always .2 of your VPC CIDR, or 169.254.169.253
export VPC_RESOLVER="169.254.169.253"

dig +short @"$VPC_RESOLVER" -t SRV "_kerberos._tcp.${IPA_DOMAIN}"
dig +short @"$VPC_RESOLVER" -t SRV "_ldap._tcp.${IPA_DOMAIN}"
dig +short @"$VPC_RESOLVER" -t TXT "_kerberos.${IPA_DOMAIN}"
dig +short @"$VPC_RESOLVER" "ipa1.${IPA_DOMAIN}"
dig +short @"$VPC_RESOLVER" "ipa-ca.${IPA_DOMAIN}"
```

> ⚠️ **If these return nothing, the private zone isn't associated with the VPC you're querying from.** Check with `aws route53 get-hosted-zone --id "$ZONE_ID" --query 'VPCs'`.

### 8.2 Side-by-side diff against FreeIPA

```bash
cat > "$WORKDIR/dns-diff.sh" <<'SCRIPT'
#!/usr/bin/env bash
# dns-diff.sh — compare IPA DNS against Route 53 record by record
OLD="${1:?old dns ip}"
NEW="${2:-169.254.169.253}"
ZONE="${3:?zone}"
RECORDS="${4:?r53-records.json}"

FAIL=0
printf '%-38s %-6s %-28s %-28s %s\n' NAME TYPE IPA ROUTE53 STATUS

python3 -c "
import json,sys
d=json.load(open('$RECORDS'))
for r in d['ResourceRecordSets']:
    if r['Type'] in ('SOA','NS'): continue
    print(r['Name'], r['Type'])
" | while read -r name rtype; do
    old=$(dig +short @"$OLD" -t "$rtype" "$name" 2>/dev/null | sort | tr '\n' ' ' | xargs)
    new=$(dig +short @"$NEW" -t "$rtype" "$name" 2>/dev/null | sort | tr '\n' ' ' | xargs)
    if [ "$old" = "$new" ]; then st="OK"; else st="MISMATCH"; FAIL=1; fi
    printf '%-38s %-6s %-28s %-28s %s\n' "$name" "$rtype" "${old:-<none>}" "${new:-<none>}" "$st"
done

exit $FAIL
SCRIPT
chmod +x "$WORKDIR/dns-diff.sh"

"$WORKDIR/dns-diff.sh" 10.0.1.10 169.254.169.253 "$IPA_DOMAIN" \
  "$WORKDIR/verify/r53-records.json" | tee "$WORKDIR/verify/diff-report.txt"

grep -c MISMATCH "$WORKDIR/verify/diff-report.txt"
```

**Do not proceed until mismatches are zero** (or every remaining one is explained and accepted).

### 8.3 Functional test on a canary host

Point one non-critical host at Route 53 and exercise the full IPA path:

```bash
# On the canary host — save the original first
sudo cp /etc/resolv.conf /etc/resolv.conf.ipa-backup
echo "nameserver 169.254.169.253" | sudo tee /etc/resolv.conf

# The tests that actually matter
dig +short -t SRV "_kerberos._tcp.${IPA_DOMAIN}"     # discovery
kinit admin                                           # Kerberos via SRV
klist
id admin                                              # SSSD/LDAP
sudo -l                                               # sudo rules
kdestroy

# Host keytab auth — the real proof
sudo kinit -k -t /etc/krb5.keytab "host/$(hostname -f)" && echo "KEYTAB OK"
sudo kdestroy

# Restore
sudo cp /etc/resolv.conf.ipa-backup /etc/resolv.conf
```

**If `kinit` fails here, do not cut over.** Debug SRV records first.

### 8.4 Gate checklist

- [ ] All SRV records resolve from within the VPC
- [ ] `ipa-ca` A record present (certificate validation)
- [ ] Realm TXT record returns `"EXAMPLE.COM"` with quotes
- [ ] Reverse/PTR records verified
- [ ] `dns-diff.sh` reports zero mismatches
- [ ] Canary host: `kinit`, `id`, `sudo`, keytab auth all pass
- [ ] TTLs are 300s on both sides (fast rollback)

---

## 9. Step 7: Resolver Cutover

**This is reversible.** Route 53 doesn't hold delegation yet — FreeIPA still has the zone data. Reverting resolvers restores everything.

### 9.1 Lower TTLs first (if not already)

```bash
ssh "$IPA_SERVER" "kinit admin && ipa dnszone-mod ${IPA_DOMAIN} --ttl=300"

# Wait for the OLD TTL to expire before proceeding.
# If your old TTL was 86400, that is 24 hours. Do not skip this.
```

### 9.2 Create the DHCP option set

```bash
aws ec2 create-dhcp-options \
  --dhcp-configurations \
    "Key=domain-name,Values=${IPA_DOMAIN}" \
    "Key=domain-name-servers,Values=AmazonProvidedDNS" \
  > "$WORKDIR/dhcp-new.json"

export DHCP_NEW=$(python3 -c "
import json
print(json.load(open('$WORKDIR/dhcp-new.json'))['DhcpOptions']['DhcpOptionsId'])
")
echo "New DHCP option set: $DHCP_NEW"

# RECORD THE OLD ONE — you need it for rollback
export DHCP_OLD=$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" \
  --query 'Vpcs[0].DhcpOptionsId' --output text)
echo "export DHCP_OLD=$DHCP_OLD" | tee -a "$WORKDIR/env.sh"
```

> **`AmazonProvidedDNS` is the right value here.** It routes queries to the VPC resolver, which answers from your private hosted zone *and* resolves AWS service endpoints natively — fixing the SSM/endpoint conflict described in the integrations guide.

### 9.3 Associate in waves

```bash
# Wave 1: dev/test VPC first if you have one
aws ec2 associate-dhcp-options \
  --dhcp-options-id "$DHCP_NEW" \
  --vpc-id "$VPC_ID"

aws ec2 describe-vpcs --vpc-ids "$VPC_ID" \
  --query 'Vpcs[0].DhcpOptionsId' --output text
```

### 9.4 Force lease renewal on critical hosts

Gotcha 11 — changes aren't immediate:

```bash
for h in $(cat "$WORKDIR/critical-hosts.txt"); do
  echo "=== $h ==="
  ssh "$h" 'sudo dhclient -r && sudo dhclient; cat /etc/resolv.conf | grep -v "^#"'
done
```

### 9.5 Verify each wave

```bash
for h in $(cat "$WORKDIR/critical-hosts.txt"); do
  printf '%-30s ' "$h"
  ssh "$h" "dig +short -t SRV _kerberos._tcp.${IPA_DOMAIN} | head -1" 2>/dev/null \
    || echo "FAILED"
done
```

---

## 10. Step 8: Soak and Validate

### 10.1 Enable Route 53 query logging

Confirms clients are actually using Route 53:

```bash
# Log group must be in us-east-1
aws logs create-log-group \
  --log-group-name "/aws/route53/${IPA_DOMAIN}" --region us-east-1

aws logs put-retention-policy \
  --log-group-name "/aws/route53/${IPA_DOMAIN}" \
  --retention-in-days 30 --region us-east-1

# For private zones use Resolver query logging
aws route53resolver create-resolver-query-log-config \
  --name "ipa-migration-${IPA_DOMAIN}" \
  --destination-arn "arn:aws:logs:${AWS_REGION}:$(aws sts get-caller-identity --query Account --output text):log-group:/aws/route53/${IPA_DOMAIN}"
```

### 10.2 Confirm FreeIPA DNS traffic has dropped

```bash
ssh "$IPA_SERVER" 'sudo rndc querylog on'
sleep 3600
ssh "$IPA_SERVER" 'sudo grep -c "query:" /var/named/data/named.run'
ssh "$IPA_SERVER" 'sudo rndc querylog off'
```

**Near zero means the cutover worked.** Non-trivial volume means something is still pointed at FreeIPA — find it before proceeding.

### 10.3 Continuous monitoring during soak

```bash
cat > "$WORKDIR/soak-check.sh" <<'SCRIPT'
#!/usr/bin/env bash
# Run every 5 minutes during the soak period
D="${IPA_DOMAIN:-example.com}"
FAIL=0

dig +short +time=3 -t SRV "_kerberos._tcp.${D}" | grep -q . \
  || { echo "CRITICAL: kerberos SRV missing"; FAIL=1; }
dig +short +time=3 -t SRV "_ldap._tcp.${D}" | grep -q . \
  || { echo "CRITICAL: ldap SRV missing"; FAIL=1; }

kinit -k -t /etc/krb5.keytab "host/$(hostname -f)" 2>/dev/null \
  && kdestroy \
  || { echo "CRITICAL: keytab auth failed"; FAIL=1; }

id admin >/dev/null 2>&1 || { echo "WARNING: SSSD resolution failed"; FAIL=1; }

[ $FAIL -eq 0 ] && echo "OK $(date -Is)"
exit $FAIL
SCRIPT
chmod +x "$WORKDIR/soak-check.sh"
```

**Soak for one week minimum before Step 9.**

---

## 11. Step 9: Retire IPA DNS

Per the DNS Migration Plan Constraint 1, the DNS role can't be cleanly removed. Target **End State A** — installed but dormant.

```bash
# 1. Final confirmation nothing queries IPA DNS
ssh "$IPA_SERVER" 'sudo rndc querylog on'; sleep 600
ssh "$IPA_SERVER" 'sudo grep -c "query:" /var/named/data/named.run; sudo rndc querylog off'

# 2. Final backup before changing state
ssh "$IPA_SERVER" 'sudo ipa-backup'

# 3. Stop and disable on every IPA server
for s in ipa1 ipa2 ipa3; do
  ssh "$s" 'sudo systemctl stop named named-pkcs11 2>/dev/null; \
            sudo systemctl disable named named-pkcs11 2>/dev/null; \
            sudo systemctl stop ipa-dnskeysyncd 2>/dev/null; \
            sudo systemctl disable ipa-dnskeysyncd 2>/dev/null'
done

# 4. Verify IPA identity still works with DNS dormant
ssh "$IPA_SERVER" 'sudo ipactl status'
ssh "$IPA_SERVER" 'kinit admin && ipa user-find --sizelimit=1'
```

> ⚠️ **`ipactl start` will still try to start DNS services.** Test a full `ipactl restart` and document the expected state, or on-call will "fix" it at 3am by restarting named — which would put a stale authoritative server back on the network.

```bash
# Test it explicitly
ssh "$IPA_SERVER" 'sudo ipactl restart; sudo ipactl status'
# Expect: named STOPPED, everything else RUNNING
```

### Post-retirement checklist

- [ ] `named` stopped and disabled on all IPA servers
- [ ] `ipa-dnskeysyncd` stopped and disabled
- [ ] `ipactl restart` tested; behaviour documented
- [ ] Monitoring updated — no alerts on stopped `named`
- [ ] Runbook says "named is intentionally down"
- [ ] Zone data in version control or IaC
- [ ] Final `ipa-backup` retained

---

## 12. Rollback Commands

### Rollback matrix

| At this point | Command | Restore time |
|---|---|---|
| Zone created, no records | `aws route53 delete-hosted-zone --id $ZONE_ID` | Instant |
| Records imported, no cutover | Nothing to do — IPA still authoritative | Instant |
| After resolver cutover | Re-associate old DHCP option set | Minutes–hours |
| After IPA DNS retired | `systemctl start named` then revert DHCP | Minutes |

### Emergency rollback script

```bash
cat > "$WORKDIR/rollback.sh" <<'SCRIPT'
#!/usr/bin/env bash
# rollback.sh — revert DNS to FreeIPA
set -euo pipefail
source "$(dirname "$0")/env.sh"

echo "=== ROLLBACK: reverting to FreeIPA DNS ==="

# 1. Bring IPA DNS back up
for s in ipa1 ipa2 ipa3; do
  ssh "$s" 'sudo systemctl start named 2>/dev/null || sudo systemctl start named-pkcs11'
done

# 2. Confirm it answers BEFORE switching anything back
if ! dig +short @10.0.1.10 -t SRV "_kerberos._tcp.${IPA_DOMAIN}" | grep -q .; then
  echo "FATAL: FreeIPA DNS is not answering. Do not proceed. Escalate."
  exit 1
fi
echo "FreeIPA DNS confirmed answering."

# 3. Revert the DHCP option set
aws ec2 associate-dhcp-options \
  --dhcp-options-id "$DHCP_OLD" \
  --vpc-id "$VPC_ID"

# 4. Force renewal on critical hosts
for h in $(cat critical-hosts.txt); do
  ssh "$h" 'sudo dhclient -r && sudo dhclient' &
done
wait

# 5. Verify
for h in $(cat critical-hosts.txt); do
  printf '%-30s ' "$h"
  ssh "$h" "dig +short -t SRV _kerberos._tcp.${IPA_DOMAIN} | head -1" || echo FAILED
done

echo "Rollback complete. Investigate root cause before retrying."
SCRIPT
chmod +x "$WORKDIR/rollback.sh"
```

### Rollback triggers

Roll back immediately if any of these occur:

- `kinit` failure rate rises on any host
- SSSD errors appear in `/var/log/sssd/`
- SRV records stop resolving
- Any host cannot resolve `ipa-ca.<domain>` (breaks cert validation)
- Application LDAP consumers start failing

---

## 13. Full Command Reference

```bash
### Environment
export AWS_REGION="us-east-1" VPC_ID="vpc-0abc" IPA_DOMAIN="example.com"
export ZONE_ID="Z0123456789ABC" WORKDIR="$HOME/ipa-r53-migration"

### Export from FreeIPA
ipa dns-update-system-records --dry-run
ipa dns-update-system-records --dry-run --out /tmp/records.nsupdate
ipa dnszone-find --raw --sizelimit=0 | awk '/idnsname:/ {print $2}'
ipa dnsrecord-find example.com --sizelimit=0 --all --raw
ldapsearch -Y GSSAPI -b "cn=dns,$(ipa env basedn | awk '{print $2}')" "(objectclass=idnsrecord)"

### Check blockers
grep -ci "^sshfprecord:" raw-records.ldif    # Gotcha 1 — private zones can't
grep -ci "^locrecord:"   raw-records.ldif    # Gotcha 5 — unsupported
ipa dnszone-find --sizelimit=0 --all | grep -i "dynamic update"   # Gotcha 6

### Create zone
aws route53 create-hosted-zone --name example.com \
  --caller-reference "ipa-$(date +%s)" \
  --vpc VPCRegion=us-east-1,VPCId=vpc-0abc \
  --hosted-zone-config Comment="From FreeIPA",PrivateZone=true

aws route53 get-hosted-zone --id "$ZONE_ID"
aws route53 associate-vpc-with-hosted-zone --hosted-zone-id "$ZONE_ID" \
  --vpc VPCRegion=us-west-2,VPCId=vpc-0def

### Convert and import
./zone2r53.py export/example.com.zone example.com batches/example.com --ttl 300
aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" \
  --change-batch file://batches/example.com/batch-001.json
aws route53 wait resource-record-sets-changed --id "$CHANGE_ID"
aws route53 get-change --id "$CHANGE_ID"

### List and verify
aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID"
aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" \
  --query "ResourceRecordSets[?Type=='SRV'].[Name,ResourceRecords[0].Value]" --output table
aws route53 get-hosted-zone --id "$ZONE_ID" --query 'HostedZone.ResourceRecordSetCount'

### Query (from inside the VPC)
dig +short @169.254.169.253 -t SRV _kerberos._tcp.example.com
dig +short @169.254.169.253 -t SRV _ldap._tcp.example.com
dig +short @169.254.169.253 -t TXT _kerberos.example.com
dig +short @169.254.169.253 ipa-ca.example.com
dig +short @169.254.169.253 -x 10.0.1.50

### VPC prerequisites
aws ec2 describe-vpc-attribute --vpc-id "$VPC_ID" --attribute enableDnsSupport
aws ec2 describe-vpc-attribute --vpc-id "$VPC_ID" --attribute enableDnsHostnames
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames

### Cutover
aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --query 'Vpcs[0].DhcpOptionsId'   # SAVE THIS
aws ec2 create-dhcp-options --dhcp-configurations \
  "Key=domain-name,Values=example.com" \
  "Key=domain-name-servers,Values=AmazonProvidedDNS"
aws ec2 associate-dhcp-options --dhcp-options-id dopt-NEW --vpc-id "$VPC_ID"
dhclient -r && dhclient      # force renewal on a host

### Functional validation
kinit admin && klist && kdestroy
kinit -k -t /etc/krb5.keytab "host/$(hostname -f)"
id admin
sudo -l

### Retire IPA DNS
rndc querylog on; sleep 600; grep -c "query:" /var/named/data/named.run; rndc querylog off
ipa-backup
systemctl stop named && systemctl disable named
systemctl stop ipa-dnskeysyncd && systemctl disable ipa-dnskeysyncd
ipactl restart && ipactl status

### Rollback
systemctl start named
aws ec2 associate-dhcp-options --dhcp-options-id "$DHCP_OLD" --vpc-id "$VPC_ID"
dhclient -r && dhclient
```

---

## Further Reading

- Route 53 supported record types: https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/ResourceRecordTypes.html
- Route 53 quotas and limits: https://docs.amazonaws.cn/en_us/Route53/latest/DeveloperGuide/DNSLimitations.html
- CreateHostedZone API: https://docs.aws.amazon.com/Route53/latest/APIReference/API_CreateHostedZone.html
- change-resource-record-sets CLI: https://docs.aws.amazon.com/cli/latest/reference/route53/change-resource-record-sets.html
- Creating a private hosted zone: https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/hosted-zone-private-creating.html
- Updating FreeIPA system DNS records remotely: https://www.freeipa.org/page/Howto/Updating_FreeIPA_system_DNS_records_on_a_remote_DNS_server

---

*Every command tested for syntax. Verify against your own environment and current AWS documentation before running in production.*
