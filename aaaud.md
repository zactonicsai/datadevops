In the EC2 console, Launch instance page:

1. Fill in Name, AMI, instance type, key pair, network settings as usual.
2. Scroll to the bottom, expand **Advanced details**.
3. Scroll to the very last field in that section — **User data** (big text box).
4. Paste:

```
#cloud-config
preserve_hostname: false
hostname: web01
fqdn: web01.example.internal
manage_etc_hosts: true
```

5. Leave "User data has already been base64 encoded" **unchecked**.
6. Launch.

The `#cloud-config` line must be the first line with no leading spaces or blank line above it, or cloud-init ignores the whole block.

If you want the hostname pulled from the Name tag instead, in that same Advanced details section set **Metadata accessible** = Enabled and **Allow tags in instance metadata** = Enabled, then use the bash script version from earlier instead of the cloud-config.

Verify after boot with `hostnamectl` — and if it didn't take, check `/var/log/cloud-init.log`.