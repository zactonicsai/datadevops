resource "aws_route53_record" "alias" {
  count   = var.alias != null ? 1 : 0
  zone_id = var.zone_id
  name    = var.name
  type    = "A"
  alias {
    name                   = var.alias.dns_name
    zone_id                = var.alias.zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "cname" {
  count   = var.alias == null ? 1 : 0
  zone_id = var.zone_id
  name    = var.name
  type    = "CNAME"
  ttl     = var.ttl
  records = [var.cname]
}
