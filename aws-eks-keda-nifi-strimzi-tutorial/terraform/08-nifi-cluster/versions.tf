terraform {
  required_version = ">= 1.8.0"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "3.2.1"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.7.2"
    }
  }
}
