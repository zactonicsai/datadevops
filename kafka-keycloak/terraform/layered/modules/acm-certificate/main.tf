resource "aws_acm_certificate" "this" {
  count                     = var.create ? 1 : 0
  domain_name               = var.domain_name
  subject_alternative_names = var.subject_alternative_names
  validation_method         = "DNS"
  tags                      = var.tags
  lifecycle { create_before_destroy = true }
}

resource "aws_route53_record" "validation" {
  for_each = var.create ? {
    for dvo in aws_acm_certificate.this[0].domain_validation_options : dvo.domain_name => {
      name = dvo.resource_record_name, record = dvo.resource_record_value, type = dvo.resource_record_type
    }
  } : {}
  zone_id         = var.route53_zone_id
  name            = each.value.name
  type            = each.value.type
  ttl             = 60
  records         = [each.value.record]
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  count                   = var.create ? 1 : 0
  certificate_arn         = aws_acm_certificate.this[0].arn
  validation_record_fqdns = [for r in aws_route53_record.validation : r.fqdn]
}
