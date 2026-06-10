# AWS CLI Command Reference — EC2 Configuration & AMIs

Every AWS CLI command used by this toolkit, what each one returns, and a trimmed
example of its JSON output. Commands are shown in **Windows cmd.exe** form (double
quotes around values). Verified against **AWS CLI v2.34.x**.

Common flags used on every command:

```cmd
--region us-east-1        REM target region (or set a default with: aws configure)
--profile myprofile       REM optional named credentials profile
--output json             REM JSON output (what the formatters parse)
```

The example outputs below are **trimmed** — real responses contain many more
fields. Run any command yourself to see the full structure.

-----

## Contents

1. [describe-instances](#1-describe-instances)
1. [describe-instances → MetadataOptions](#2-describe-instances--metadataoptions)
1. [describe-instance-status](#3-describe-instance-status)
1. [describe-iam-instance-profile-associations](#4-describe-iam-instance-profile-associations)
1. [IAM role permissions](#5-iam-role-permissions)
1. [describe-security-groups](#6-describe-security-groups)
1. [describe-security-group-rules](#7-describe-security-group-rules)
1. [describe-network-interfaces](#8-describe-network-interfaces)
1. [describe-volumes](#9-describe-volumes)
1. [describe-subnets](#10-describe-subnets)
1. [describe-vpcs](#11-describe-vpcs)
1. [describe-key-pairs](#12-describe-key-pairs)
1. [describe-tags](#13-describe-tags)
1. [describe-images –owners self](#14-describe-images---owners-self)
1. [describe-images –image-ids](#15-describe-images---image-ids)

-----

## 1. describe-instances

```cmd
aws ec2 describe-instances --region us-east-1 --output json
```

**Returns:** every EC2 instance in the region, grouped under `Reservations[]`,
each holding `Instances[]`. This is the richest call — it carries core config
(type, state, AMI, placement), networking, attached security groups, the IAM
instance profile, block-device mappings and tags. Most other sections join back
to the `InstanceId` found here.

**Key fields:** `InstanceId`, `InstanceType`, `State.Name`, `ImageId` (the AMI),
`Placement.AvailabilityZone`, `VpcId`, `SubnetId`, `KeyName`, `SecurityGroups[]`,
`IamInstanceProfile.Arn`, `LaunchTime`, `Tags[]`.

**Example output (trimmed):**

```json
{
  "Reservations": [
    {
      "ReservationId": "r-0123456789abcdef0",
      "OwnerId": "123456789012",
      "Instances": [
        {
          "InstanceId": "i-0abc123def4567890",
          "InstanceType": "t3.micro",
          "ImageId": "ami-0aaa1111bbbb2222c",
          "State": { "Code": 16, "Name": "running" },
          "Placement": { "AvailabilityZone": "us-east-1a", "Tenancy": "default" },
          "VpcId": "vpc-01aa22bb33cc44dd5",
          "SubnetId": "subnet-01aa22bb33cc44dd5",
          "KeyName": "prod-key",
          "LaunchTime": "2025-04-01T10:00:00+00:00",
          "SecurityGroups": [
            { "GroupId": "sg-01aa22bb33cc44dd5", "GroupName": "web-sg" }
          ],
          "IamInstanceProfile": {
            "Arn": "arn:aws:iam::123456789012:instance-profile/web-role",
            "Id": "AIPAEXAMPLEEXAMPLE"
          },
          "Tags": [ { "Key": "Name", "Value": "web-1" } ]
        }
      ]
    }
  ]
}
```

> **Tip:** filter server-side, e.g. only running instances:
> `aws ec2 describe-instances --filters "Name=instance-state-name,Values=running" --output json`

-----

## 2. describe-instances → MetadataOptions

Same command as #1; this section reads the `MetadataOptions` object on each
instance (no separate API call).

```cmd
aws ec2 describe-instances --region us-east-1 --output json
```

**Returns:** the Instance Metadata Service (IMDS) configuration per instance —
whether IMDSv2 is enforced and how far metadata requests may travel.

**Key fields:** `HttpTokens` (`required` = **IMDSv2 enforced**, recommended),
`HttpEndpoint` (enabled/disabled), `HttpPutResponseHopLimit` (a value > 1 can let
containers reach instance credentials), `InstanceMetadataTags`, `HttpProtocolIpv6`.

**Example output (the relevant slice):**

```json
{
  "InstanceId": "i-0abc123def4567890",
  "MetadataOptions": {
    "State": "applied",
    "HttpTokens": "required",
    "HttpPutResponseHopLimit": 2,
    "HttpEndpoint": "enabled",
    "HttpProtocolIpv6": "disabled",
    "InstanceMetadataTags": "disabled"
  }
}
```

-----

## 3. describe-instance-status

```cmd
aws ec2 describe-instance-status --include-all-instances --region us-east-1 --output json
```

**Returns:** the instance/system reachability checks and any scheduled events
(e.g. planned maintenance reboots). Without `--include-all-instances`, only
`running` instances are shown; the flag adds stopped/pending ones too.

**Key fields:** `InstanceId`, `InstanceState.Name`, `InstanceStatus.Status`
(instance check), `SystemStatus.Status` (system check), `Events[].Code`.

**Example output (trimmed):**

```json
{
  "InstanceStatuses": [
    {
      "InstanceId": "i-0abc123def4567890",
      "AvailabilityZone": "us-east-1a",
      "InstanceState": { "Code": 16, "Name": "running" },
      "InstanceStatus": { "Status": "ok", "Details": [ { "Name": "reachability", "Status": "passed" } ] },
      "SystemStatus": { "Status": "ok", "Details": [ { "Name": "reachability", "Status": "passed" } ] },
      "Events": []
    }
  ]
}
```

-----

## 4. describe-iam-instance-profile-associations

```cmd
aws ec2 describe-iam-instance-profile-associations --region us-east-1 --output json
```

**Returns:** the link between each instance and the IAM **instance profile** it
runs as. An instance profile is a container that holds exactly one IAM role, so
this is how you discover which role an instance assumes. The profile ARN’s last
path segment is the profile name (usually the same as the role name).

**Key fields:** `InstanceId`, `IamInstanceProfile.Arn`, `State`
(`associated`/`associating`), `AssociationId`.

**Example output:**

```json
{
  "IamInstanceProfileAssociations": [
    {
      "InstanceId": "i-0abc123def4567890",
      "State": "associated",
      "AssociationId": "iip-assoc-0db249b1f25fa24b8",
      "IamInstanceProfile": {
        "Id": "AIPAEXAMPLEEXAMPLE",
        "Arn": "arn:aws:iam::123456789012:instance-profile/web-role"
      }
    }
  ]
}
```

> The actual **permissions** of that role are not here — see section 5.

-----

## 5. IAM role permissions

This is a small chain of `iam` commands (run by `fetch_role_permissions.py`),
not a single call. For each role found in section 4:

```cmd
REM 1. profile -> contained role name
aws iam get-instance-profile --instance-profile-name web-role --output json

REM 2. managed policies attached to the role
aws iam list-attached-role-policies --role-name web-role --output json

REM 3. each managed policy's current document
aws iam get-policy --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess --output json
aws iam get-policy-version --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess --version-id v3 --output json

REM 4. inline policies defined directly on the role
aws iam list-role-policies --role-name web-role --output json
aws iam get-role-policy --role-name web-role --policy-name logs --output json
```

**Returns:** the effective permissions of each instance role — the full JSON
policy documents for both attached **managed** policies and **inline** policies.

**Example — a managed policy document (`get-policy-version`):**

```json
{
  "PolicyVersion": {
    "VersionId": "v3",
    "IsDefaultVersion": true,
    "Document": {
      "Version": "2012-10-17",
      "Statement": [
        {
          "Effect": "Allow",
          "Action": [ "s3:Get*", "s3:List*" ],
          "Resource": "*"
        }
      ]
    }
  }
}
```

**Example — an inline policy (`get-role-policy`):**

```json
{
  "RoleName": "web-role",
  "PolicyName": "logs",
  "PolicyDocument": {
    "Version": "2012-10-17",
    "Statement": [
      { "Effect": "Allow", "Action": "logs:PutLogEvents", "Resource": "*" }
    ]
  }
}
```

The toolkit consolidates these into `role_permissions.json`, keyed by role name.

-----

## 6. describe-security-groups

```cmd
aws ec2 describe-security-groups --region us-east-1 --output json
```

**Returns:** the security group inventory — each group’s identity plus its
ingress (`IpPermissions`) and egress (`IpPermissionsEgress`) rule arrays. The
group’s rules are easier to read flattened (section 7); which instances use a
group comes from section 1.

**Key fields:** `GroupId`, `GroupName`, `VpcId`, `Description`, `IpPermissions[]`,
`IpPermissionsEgress[]`.

**Example output (trimmed):**

```json
{
  "SecurityGroups": [
    {
      "GroupId": "sg-01aa22bb33cc44dd5",
      "GroupName": "web-sg",
      "VpcId": "vpc-01aa22bb33cc44dd5",
      "Description": "web tier",
      "IpPermissions": [
        {
          "IpProtocol": "tcp",
          "FromPort": 443,
          "ToPort": 443,
          "IpRanges": [ { "CidrIp": "0.0.0.0/0", "Description": "https" } ]
        }
      ],
      "IpPermissionsEgress": [
        { "IpProtocol": "-1", "IpRanges": [ { "CidrIp": "0.0.0.0/0" } ] }
      ]
    }
  ]
}
```

-----

## 7. describe-security-group-rules

```cmd
aws ec2 describe-security-group-rules --region us-east-1 --output json
```

**Returns:** the same permissions as section 6, but **flattened to one rule per
row** with a stable `SecurityGroupRuleId`. This is the cleanest form for an
audit: each entry says direction, protocol, port range and source/destination.

**Key fields:** `SecurityGroupRuleId`, `GroupId`, `IsEgress` (true = egress),
`IpProtocol` (`-1` = all), `FromPort`/`ToPort`, and one of `CidrIpv4`,
`CidrIpv6`, `ReferencedGroupInfo.GroupId`, or `PrefixListId`.

**Example output:**

```json
{
  "SecurityGroupRules": [
    {
      "SecurityGroupRuleId": "sgr-0aa11bb22cc33dd44",
      "GroupId": "sg-01aa22bb33cc44dd5",
      "IsEgress": false,
      "IpProtocol": "tcp",
      "FromPort": 443,
      "ToPort": 443,
      "CidrIpv4": "0.0.0.0/0",
      "Description": "https"
    },
    {
      "SecurityGroupRuleId": "sgr-0bb22cc33dd44ee55",
      "GroupId": "sg-01aa22bb33cc44dd5",
      "IsEgress": true,
      "IpProtocol": "-1",
      "FromPort": -1,
      "ToPort": -1,
      "CidrIpv4": "0.0.0.0/0",
      "Description": "all outbound"
    }
  ]
}
```

> `IpProtocol: "-1"` with ports `-1` means **all protocols, all ports**.

-----

## 8. describe-network-interfaces

```cmd
aws ec2 describe-network-interfaces --region us-east-1 --output json
```

**Returns:** elastic network interfaces (ENIs) — the private IP, any associated
public IP, the subnet/VPC, and the instance they attach to. Join on
`Attachment.InstanceId` back to section 1.

**Key fields:** `NetworkInterfaceId`, `Attachment.InstanceId`,
`PrivateIpAddress`, `Association.PublicIp`, `SubnetId`, `VpcId`, `Status`.

**Example output (trimmed):**

```json
{
  "NetworkInterfaces": [
    {
      "NetworkInterfaceId": "eni-0aa11bb22cc33dd44",
      "Status": "in-use",
      "PrivateIpAddress": "10.0.1.5",
      "SubnetId": "subnet-01aa22bb33cc44dd5",
      "VpcId": "vpc-01aa22bb33cc44dd5",
      "Attachment": { "InstanceId": "i-0abc123def4567890", "DeviceIndex": 0 },
      "Association": { "PublicIp": "54.1.2.3", "IpOwnerId": "amazon" }
    }
  ]
}
```

-----

## 9. describe-volumes

```cmd
aws ec2 describe-volumes --region us-east-1 --output json
```

**Returns:** EBS volumes with size, type, IOPS and encryption status, plus an
`Attachments[]` array linking each volume to an instance and device name.

**Key fields:** `VolumeId`, `VolumeType`, `Size`, `Iops`, `Encrypted`, `State`,
`Attachments[].InstanceId`, `Attachments[].Device`.

**Example output (trimmed):**

```json
{
  "Volumes": [
    {
      "VolumeId": "vol-0aa11bb22cc33dd44",
      "VolumeType": "gp3",
      "Size": 20,
      "Iops": 3000,
      "Encrypted": true,
      "State": "in-use",
      "Attachments": [
        { "InstanceId": "i-0abc123def4567890", "Device": "/dev/xvda", "State": "attached" }
      ]
    }
  ]
}
```

-----

## 10. describe-subnets

```cmd
aws ec2 describe-subnets --region us-east-1 --output json
```

**Returns:** subnets with their CIDR block, AZ, free-IP count and whether they
auto-assign public IPs. Join on `SubnetId` to sections 1/8, and `VpcId` to
section 11.

**Key fields:** `SubnetId`, `VpcId`, `CidrBlock`, `AvailabilityZone`,
`AvailableIpAddressCount`, `MapPublicIpOnLaunch`.

**Example output (trimmed):**

```json
{
  "Subnets": [
    {
      "SubnetId": "subnet-01aa22bb33cc44dd5",
      "VpcId": "vpc-01aa22bb33cc44dd5",
      "CidrBlock": "10.0.1.0/24",
      "AvailabilityZone": "us-east-1a",
      "AvailableIpAddressCount": 250,
      "MapPublicIpOnLaunch": true,
      "Tags": [ { "Key": "Name", "Value": "public-a" } ]
    }
  ]
}
```

-----

## 11. describe-vpcs

```cmd
aws ec2 describe-vpcs --region us-east-1 --output json
```

**Returns:** the virtual networks. Join on `VpcId` to subnets, ENIs, security
groups and instances.

**Key fields:** `VpcId`, `CidrBlock`, `State`, `IsDefault`, `InstanceTenancy`.

**Example output (trimmed):**

```json
{
  "Vpcs": [
    {
      "VpcId": "vpc-01aa22bb33cc44dd5",
      "CidrBlock": "10.0.0.0/16",
      "State": "available",
      "IsDefault": false,
      "InstanceTenancy": "default",
      "Tags": [ { "Key": "Name", "Value": "main" } ]
    }
  ]
}
```

-----

## 12. describe-key-pairs

```cmd
aws ec2 describe-key-pairs --region us-east-1 --output json
```

**Returns:** registered SSH key pairs (metadata only — never the private key).
Join on `KeyName` to the `KeyName` field on instances in section 1.

**Key fields:** `KeyName`, `KeyPairId`, `KeyType`, `KeyFingerprint`, `CreateTime`.

**Example output:**

```json
{
  "KeyPairs": [
    {
      "KeyName": "prod-key",
      "KeyPairId": "key-0aa11bb22cc33dd44",
      "KeyType": "rsa",
      "KeyFingerprint": "ab:cd:ef:00:11:22:33:44:55:66:77:88:99:aa:bb:cc",
      "CreateTime": "2024-01-01T00:00:00+00:00"
    }
  ]
}
```

-----

## 13. describe-tags

```cmd
aws ec2 describe-tags --region us-east-1 --output json
```

**Returns:** every tag on every EC2 resource in the region as a flat list. Join
on `ResourceId` to whichever section owns that resource.

**Key fields:** `ResourceType`, `ResourceId`, `Key`, `Value`.

**Example output:**

```json
{
  "Tags": [
    { "ResourceType": "instance", "ResourceId": "i-0abc123def4567890", "Key": "Name", "Value": "web-1" },
    { "ResourceType": "volume",   "ResourceId": "vol-0aa11bb22cc33dd44", "Key": "Env",  "Value": "prod" }
  ]
}
```

-----

## 14. describe-images –owners self

```cmd
aws ec2 describe-images --owners self --region us-east-1 --output json
```

**Returns:** AMIs **owned by your account** — the images you can launch from.
`--owners self` is essential; without it the call would try to return every
public AMI. Join on `ImageId` to the `ImageId` on instances (section 1).

**Key fields:** `ImageId`, `Name`, `State`, `Architecture`, `PlatformDetails`,
`RootDeviceType`, `RootDeviceName`, `BlockDeviceMappings[]`, `CreationDate`.

**Example output (trimmed):**

```json
{
  "Images": [
    {
      "ImageId": "ami-0aaa1111bbbb2222c",
      "Name": "custom-web-2025-01",
      "State": "available",
      "Architecture": "x86_64",
      "PlatformDetails": "Linux/UNIX",
      "RootDeviceType": "ebs",
      "RootDeviceName": "/dev/xvda",
      "CreationDate": "2025-01-15T00:00:00.000Z",
      "Public": false,
      "BlockDeviceMappings": [
        { "DeviceName": "/dev/xvda", "Ebs": { "VolumeSize": 20, "VolumeType": "gp3" } }
      ]
    }
  ]
}
```

-----

## 15. describe-images –image-ids

```cmd
aws ec2 describe-images --image-ids ami-0aaa1111bbbb2222c ami-0ddd3333eeee4444f --region us-east-1 --output json
```

**Returns:** details for the **specific AMIs your instances were launched from**,
including ones owned by Amazon or the Marketplace (which `--owners self` would
miss). The toolkit gathers the distinct `ImageId` values from section 1 first,
then passes them here so the instance → AMI relationship never has a gap. Same
field shape as section 14, with an `OwnerId` worth noting.

**Building the id list on Windows (from `fetch_all.cmd`):**

```cmd
for /f "usebackq delims=" %%I in (`aws ec2 describe-instances ^
    --query "Reservations[].Instances[].ImageId" --output text`) do set "IMG_IDS=%%I"
aws ec2 describe-images --image-ids %IMG_IDS% --region us-east-1 --output json
```

**Example output (trimmed):**

```json
{
  "Images": [
    {
      "ImageId": "ami-0aaa1111bbbb2222c",
      "Name": "custom-web-2025-01",
      "OwnerId": "123456789012",
      "State": "available",
      "Architecture": "x86_64",
      "PlatformDetails": "Linux/UNIX",
      "RootDeviceType": "ebs",
      "Public": false
    }
  ]
}
```

-----

## Putting it together

```cmd
REM Fetch all of the above into .\json\
fetch_all.cmd us-east-1 myprofile

REM Turn the JSON into one Markdown reference
python build_docs.py
```

|Concern         |Command                                     |Joins to                   |
|----------------|--------------------------------------------|---------------------------|
|Instance config |`describe-instances`                        |everything via `InstanceId`|
|Metadata / IMDS |`describe-instances` (MetadataOptions)      |instances                  |
|Health          |`describe-instance-status`                  |instances                  |
|Role link       |`describe-iam-instance-profile-associations`|role permissions           |
|Role permissions|`iam get/list-*-role-policies`              |the role above             |
|SG inventory    |`describe-security-groups`                  |instances, SG rules        |
|SG permissions  |`describe-security-group-rules`             |security groups            |
|Networking      |`describe-network-interfaces`               |instances, subnets, VPCs   |
|Storage         |`describe-volumes`                          |instances                  |
|Subnets         |`describe-subnets`                          |VPCs, instances            |
|VPCs            |`describe-vpcs`                             |subnets, instances         |
|Key pairs       |`describe-key-pairs`                        |instances                  |
|Tags            |`describe-tags`                             |every resource             |
|AMIs owned      |`describe-images --owners self`             |instances                  |
|AMIs in use     |`describe-images --image-ids ...`           |instances                  |

**Required permissions:** `ec2:Describe*`, `iam:Get*`, `iam:List*` (read-only).