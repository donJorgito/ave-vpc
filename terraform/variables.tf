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

variable "ad_index" {
  description = "Índice de Availability Domain a usar (0, 1 o 2 según la región)"
  default     = 0
}

variable "ssh_public_key" {
  description = "Clave pública SSH para acceder al servidor (pegar contenido de ~/.ssh/id_rsa.pub o id_ed25519.pub)"
}
