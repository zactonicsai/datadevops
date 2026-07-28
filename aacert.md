Then issue two certs from one module, and be deliberate about which one costs money.

**Cost check first:** ACM now charges $7 per standard FQDN and $79 per wildcard name for exportable public certificates, billed at issuance and again at each renewal, while non-exportable certs stay free. So only the EC2 leg should be exportable — and only if that Keycloak is *directly* internet-facing. If your EC2 Keycloak sits behind the same ALB, skip the paid cert entirely: the ALB doesn't validate backend certificates, so a free self-signed cert on the instance gives you end-to-end encryption.

**Shared module** — `modules/acm/main.tf`:

```hcl
variable "domain_name" { type = string }
variable "zone_id"     { type = string }
variable "exportable"  { type = bool, default = false }

resource "aws_acm_certificate" "this" {
  domain_name       = var.domain_name
  validation_method = "DNS"
  key_algorithm     = "EC_prime256v1"
  options { export = var.exportable ? "ENABLED" : "DISABLED" }
  lifecycle { create_before_destroy = true }
}

resource "aws_route53_record" "validation" {
  for_each = {
    for d in aws_acm_certificate.this.domain_validation_options :
    d.domain_name => { name = d.resource_record_name, type = d.resource_record_type, record = d.resource_record_value }
  }
  zone_id         = var.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [for r in aws_route53_record.validation : r.fqdn]
}

output "arn" { value = aws_acm_certificate_validation.this.certificate_arn }
```

`options { export = ... }` needs AWS provider ≥ 6.4, and the flag is immutable after issuance — flipping it forces a replacement.

**Root:**

```hcl
module "kc_alb_cert" {
  source      = "./modules/acm"
  domain_name = "auth.example.com"
  zone_id     = var.zone_id
  exportable  = false          # free, for the ECS/EKS ALB listener
}

module "kc_ec2_cert" {
  source      = "./modules/acm"
  domain_name = "sso.example.com"
  zone_id     = var.zone_id
  exportable  = true           # $7, key lands on the instance
}
```

**EC2 leg — don't put the key in Terraform state.** There's still no `aws_acm_certificate_export` resource, and using `external`/`local-exec` would write the private key into your state file in plaintext. Give the instance an IAM role and let it fetch its own key at boot:

```hcl
data "aws_iam_policy_document" "export" {
  statement {
    actions   = ["acm:ExportCertificate"]
    resources = [module.kc_ec2_cert.arn]
  }
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.cert_passphrase.arn]
  }
}
```

Then in user_data:

```bash
PASS=$(aws secretsmanager get-secret-value --secret-id kc-cert-pass --query SecretString --output text)
aws acm export-certificate --certificate-arn "$CERT_ARN" \
  --passphrase "$(echo -n $PASS | base64)" > /tmp/export.json

jq -r .Certificate      /tmp/export.json  > /etc/keycloak/tls.crt
jq -r .PrivateKey       /tmp/export.json  > /etc/keycloak/tls.key.enc
openssl ec -in /etc/keycloak/tls.key.enc -passin "pass:$PASS" -out /etc/keycloak/tls.key
chmod 600 /etc/keycloak/tls.key && shred -u /tmp/export.json
```

Keycloak 25+ takes PEM directly — `KC_HTTPS_CERTIFICATE_FILE` and `KC_HTTPS_CERTIFICATE_KEY_FILE`, no PKCS12 conversion needed. Note the exported key is always passphrase-encrypted, so the `openssl ec` decrypt step isn't optional.

**The renewal gotcha:** ACM auto-renews the exportable cert, but nothing pushes the new key to your instance — and ACM already issues at 198-day validity ahead of the CA/Browser Forum changes, so that's roughly twice a year. Wire an EventBridge rule on the ACM renewal event to trigger SSM Run Command that re-runs the export script and restarts Keycloak. Without that, you get a surprise outage at renewal.

Want me to write out the EventBridge + SSM renewal piece, or the ECS task definition side with the proxy headers config?