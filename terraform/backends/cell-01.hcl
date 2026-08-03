bucket         = "acme-platform-tfstate-eu-central-1"
key            = "cells/cell-01/terraform.tfstate"
region         = "eu-central-1"
dynamodb_table = "acme-platform-tfstate-lock"
encrypt        = true
kms_key_id     = "alias/acme-tfstate"
