output "public_ip" {
  value       = oci_core_instance.server.public_ip
  description = "IP pública del servidor ave-vpc"
}

output "ssh_command" {
  value       = "ssh ubuntu@${oci_core_instance.server.public_ip}"
  description = "Comando SSH para conectarte al servidor"
}
