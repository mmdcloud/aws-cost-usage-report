terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }

  # ---------------------------------------------------------------------------
  # Remote State Backend
  # Uncomment and populate before first apply.
  # ---------------------------------------------------------------------------
  # backend "s3" {
  #   bucket         = "<tfstate-bucket>"
  #   key            = "cost-intelligence/terraform.tfstate"
  #   region         = "us-east-1"
  #   encrypt        = true
  #   kms_key_id     = "<tfstate-kms-key-arn>"
  #   dynamodb_table = "<tfstate-lock-table>"
  # }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "aws-cost-intelligence"
      Environment = var.environment
      ManagedBy   = "terraform"
      Owner       = var.team_name
    }
  }
}

provider "random" {}