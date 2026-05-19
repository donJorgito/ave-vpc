### ave-vpc.REQ-SW-04 - Terraform 1.5 o superior

**Description:**

El aprovisionamiento opcional del VPS en Oracle Cloud usa Terraform
para crear la VCN, subnet, internet gateway, security list y la
instancia VM. Versión mínima: 1.5.

**Parent Requirement:** N/A

**Acceptance Criteria:**

- `terraform -version` devuelve una versión `1.5.x` o superior.
- Los archivos `.tf` en `terraform/` validan con `terraform validate`.
