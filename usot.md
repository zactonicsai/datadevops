```bash
# Set hostname (persists across reboots)
sudo hostnamectl set-hostname myserver.example.com

# Verify
hostnamectl
```

Then add it to `/etc/hosts` so `sudo` and local lookups don't complain:

```bash
echo "127.0.0.1 myserver.example.com myserver" | sudo tee -a /etc/hosts
```

To stop cloud-init from resetting the hostname on reboot (common on Amazon Linux/RHEL AMIs):

```bash
echo "preserve_hostname: true" | sudo tee /etc/cloud/cloud.cfg.d/99_hostname.cfg
```

Log out and back in (or `exec bash`) to see the new name in your prompt. Note this only changes the OS hostname — DNS and the EC2 console "Name" tag are separate.