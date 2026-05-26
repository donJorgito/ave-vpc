#!/usr/bin/env bash
# check_terraform_tfvars_example.sh — verifica el ejemplo de tfvars.
set -euo pipefail

test -f terraform/terraform.tfvars.example || {
    echo "ERROR: terraform.tfvars.example no existe"
    exit 1
}
grep -q "tenancy_ocid" terraform/terraform.tfvars.example || {
    echo "ERROR: tenancy_ocid ausente en tfvars.example"
    exit 1
}
echo "✓ tenancy_ocid en tfvars.example"
