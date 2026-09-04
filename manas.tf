terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" {
  region = var.region
}

# ---------- Variables ----------
variable "region"         { default = "eu-west-1" }
variable "instance_type"  { default = "t3.small" }
variable "key_name"       { description = "Existing EC2 key pair name" }
variable "allowed_cidr"   { default = "0.0.0.0/0" }

variable "kafka_bootstrap" { description = "e.g. broker1:9092,broker2:9092" }

variable "keycloak_issuer" { description = "e.g. https://keycloak.example.com/realms/myrealm" }
variable "oidc_client_id"  { default = "kafka-ui" }
variable "oidc_client_secret" {
  sensitive = true
}

# ---------- Data ----------
data "aws_vpc" "default" { default = true }

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

# ---------- Security group ----------
resource "aws_security_group" "kafka_ui" {
  name   = "kafka-ui"
  vpc_id = data.aws_vpc.default.id

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
  }
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ---------- EC2 ----------
resource "aws_instance" "kafka_ui" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_type
  key_name                    = var.key_name
  vpc_security_group_ids      = [aws_security_group.kafka_ui.id]
  associate_public_ip_address = true

  user_data = <<-EOF
    #!/bin/bash
    dnf install -y docker
    systemctl enable --now docker

    docker run -d --name kafka-ui --restart unless-stopped -p 8080:8080 \
      -e KAFKA_CLUSTERS_0_NAME=main \
      -e KAFKA_CLUSTERS_0_BOOTSTRAPSERVERS='${var.kafka_bootstrap}' \
      -e AUTH_TYPE=OAUTH2 \
      -e AUTH_OAUTH2_CLIENT_KEYCLOAK_CLIENTID='${var.oidc_client_id}' \
      -e AUTH_OAUTH2_CLIENT_KEYCLOAK_CLIENTSECRET='${var.oidc_client_secret}' \
      -e AUTH_OAUTH2_CLIENT_KEYCLOAK_SCOPE=openid \
      -e AUTH_OAUTH2_CLIENT_KEYCLOAK_ISSUER_URI='${var.keycloak_issuer}' \
      -e AUTH_OAUTH2_CLIENT_KEYCLOAK_USER_NAME_ATTRIBUTE=preferred_username \
      -e AUTH_OAUTH2_CLIENT_KEYCLOAK_CLIENT_NAME=keycloak \
      -e AUTH_OAUTH2_CLIENT_KEYCLOAK_PROVIDER=keycloak \
      -e AUTH_OAUTH2_CLIENT_KEYCLOAK_CUSTOM_PARAMS_TYPE=oauth \
      -e AUTH_OAUTH2_CLIENT_KEYCLOAK_CUSTOM_PARAMS_ROLES_FIELD=roles \
      provectuslabs/kafka-ui:latest
  EOF

  tags = { Name = "kafka-ui" }
}

# ---------- Outputs ----------
output "kafka_ui_url" {
  value = "http://${aws_instance.kafka_ui.public_ip}:8080"
}

output "keycloak_redirect_uri" {
  value = "http://${aws_instance.kafka_ui.public_ip}:8080/login/oauth2/code/keycloak"
}
