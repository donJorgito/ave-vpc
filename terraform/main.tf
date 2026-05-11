terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 6.0"
    }
  }
}

provider "oci" {
  tenancy_ocid = var.tenancy_ocid
  region       = var.region
  # Lee credenciales de ~/.oci/config (perfil DEFAULT)
}

# ─── Datos dinámicos ──────────────────────────────────────────────────────────

data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

# Busca la imagen Ubuntu 24.04 más reciente compatible con el shape elegido
data "oci_core_images" "ubuntu_24" {
  compartment_id           = var.tenancy_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04"
  shape                    = var.shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
  state                    = "AVAILABLE"
}

# ─── Red ──────────────────────────────────────────────────────────────────────

resource "oci_core_vcn" "main" {
  compartment_id = var.tenancy_ocid
  cidr_block     = "10.0.0.0/16"
  display_name   = "ave-vpc-vcn"
  dns_label      = "avevpc"
}

resource "oci_core_internet_gateway" "main" {
  compartment_id = var.tenancy_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "ave-vpc-igw"
  enabled        = true
}

resource "oci_core_route_table" "main" {
  compartment_id = var.tenancy_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "ave-vpc-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    network_entity_id = oci_core_internet_gateway.main.id
  }
}

resource "oci_core_security_list" "main" {
  compartment_id = var.tenancy_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "ave-vpc-sl"

  # Todo el tráfico saliente permitido
  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }

  # SSH
  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"
    tcp_options {
      min = 22
      max = 22
    }
  }

  # mlvpn UDP (puertos 5080-5082)
  ingress_security_rules {
    protocol = "17"
    source   = "0.0.0.0/0"
    udp_options {
      min = 5080
      max = 5082
    }
  }

  # ICMP (ping)
  ingress_security_rules {
    protocol = "1"
    source   = "0.0.0.0/0"
    icmp_options {
      type = 8
    }
  }
}

resource "oci_core_subnet" "main" {
  compartment_id    = var.tenancy_ocid
  vcn_id            = oci_core_vcn.main.id
  cidr_block        = "10.0.0.0/24"
  display_name      = "ave-vpc-subnet"
  dns_label         = "avevpcsub"
  route_table_id    = oci_core_route_table.main.id
  security_list_ids = [oci_core_security_list.main.id]
}

# ─── Instancia VM ─────────────────────────────────────────────────────────────

resource "oci_core_instance" "server" {
  compartment_id      = var.tenancy_ocid
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[var.ad_index].name
  display_name        = "ave-vpc-server"
  shape               = var.shape

  dynamic "shape_config" {
    for_each = var.shape == "VM.Standard.A1.Flex" ? [1] : []
    content {
      ocpus         = 1
      memory_in_gbs = 6
    }
  }

  source_details {
    source_type = "image"
    source_id   = data.oci_core_images.ubuntu_24.images[0].id
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.main.id
    assign_public_ip = true
    display_name     = "ave-vpc-vnic"
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
  }

  # Sin timeout agresivo — si falla por capacidad Terraform reporta el error
  timeouts {
    create = "10m"
  }
}
