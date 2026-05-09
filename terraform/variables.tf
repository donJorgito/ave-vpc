variable "tenancy_ocid" {
  description = "OCID de tu tenancy (Profile > Tenancy en la consola)"
}

variable "region" {
  description = "Región de OCI"
  default     = "eu-madrid-1"
}

variable "shape" {
  description = "Shape de la VM. A1.Flex (ARM, más RAM) o E2.1.Micro (x86)"
  default     = "VM.Standard.A1.Flex"
}

variable "ssh_public_key" {
  description = "Clave pública SSH para acceder al servidor"
  default     = "ssh-ed25519 TU_CLAVE_PUBLICA_SSH TU_EMAIL"
}
