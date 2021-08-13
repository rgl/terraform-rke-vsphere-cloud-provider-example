# see https://github.com/hashicorp/terraform
terraform {
  required_version = "1.0.4"
  required_providers {
    # see https://registry.terraform.io/providers/hashicorp/random
    random = {
      source = "hashicorp/random"
      version = "3.1.0"
    }
    # see https://registry.terraform.io/providers/hashicorp/template
    template = {
      source = "hashicorp/template"
      version = "2.2.0"
    }
    # see https://registry.terraform.io/providers/hashicorp/vsphere
    # see https://github.com/hashicorp/terraform-provider-vsphere
    vsphere = {
      source = "hashicorp/vsphere"
      version = "2.0.2"
    }
    # see https://registry.terraform.io/providers/rancher/rke
    # see https://github.com/rancher/terraform-provider-rke
    rke = {
      source = "rancher/rke"
      version = "1.2.3"
    }
  }
}

variable "vsphere_user" {
  default = "administrator@vsphere.local"
}

variable "vsphere_password" {
  default = "password"
  sensitive = true
}

variable "vsphere_server" {
  default = "vsphere.local"
}

variable "vsphere_datacenter" {
  default = "Datacenter"
}

variable "vsphere_compute_cluster" {
  default = "Cluster"
}

variable "vsphere_network" {
  default = "VM Network"
}

variable "vsphere_datastore" {
  default = "Datastore"
}

variable "vsphere_ubuntu_template" {
  default = "vagrant-templates/ubuntu-20.04-amd64-vsphere"
}

variable "vsphere_folder" {
  default = "rke_example"
}

variable "prefix" {
  default = "rke_example"
}

variable "kubernetes_version" {
  default = "v1.20.8-rancher1-1"
}

variable "controller_count" {
  type = number
  default = 1
  validation {
    condition = var.controller_count >= 1
    error_message = "Must be 1 or more."
  }
}

variable "worker_count" {
  type = number
  default = 1
  validation {
    condition = var.worker_count >= 1
    error_message = "Must be 1 or more."
  }
}

provider "vsphere" {
  user = var.vsphere_user
  password = var.vsphere_password
  vsphere_server = var.vsphere_server
  allow_unverified_ssl = true
}

provider "rke" {
  log_file = "rke.log"
}

data "vsphere_datacenter" "datacenter" {
  name = var.vsphere_datacenter
}

data "vsphere_compute_cluster" "compute_cluster" {
  name = var.vsphere_compute_cluster
  datacenter_id = data.vsphere_datacenter.datacenter.id
}

data "vsphere_datastore" "datastore" {
  name = var.vsphere_datastore
  datacenter_id = data.vsphere_datacenter.datacenter.id
}

data "vsphere_network" "network" {
  name = var.vsphere_network
  datacenter_id = data.vsphere_datacenter.datacenter.id
}

data "vsphere_virtual_machine" "ubuntu_template" {
  name = var.vsphere_ubuntu_template
  datacenter_id = data.vsphere_datacenter.datacenter.id
}

# a cloud-init for the controller nodes.
# see journactl -u cloud-init
# see /run/cloud-init/*.log
# see less /usr/share/doc/cloud-init/examples/cloud-config.txt.gz
# see https://www.terraform.io/docs/providers/template/d/cloudinit_config.html
# see https://www.terraform.io/docs/configuration/expressions.html#string-literals
data "template_cloudinit_config" "controller" {
  count = var.controller_count
  gzip = true
  base64_encode = true
  part {
    content_type = "text/cloud-config"
    content = <<-EOF
      #cloud-config
      hostname: c${count.index}
      users:
        - name: vagrant
          passwd: '$6$rounds=4096$NQ.EmIrGxn$rTvGsI3WIsix9TjWaDfKrt9tm3aa7SX7pzB.PSjbwtLbsplk1HsVzIrZbXwQNce6wmeJXhCq9YFJHDx9bXFHH.'
          lock_passwd: false
          ssh-authorized-keys:
            - ${file("~/.ssh/id_rsa.pub")}
      runcmd:
        - sed -i '/vagrant insecure public key/d' /home/vagrant/.ssh/authorized_keys
        # make sure the vagrant account is not expired.
        # NB this is needed when the base image expires the vagrant account.
        - usermod --expiredate '' vagrant
      EOF
  }
}

# a cloud-init for the worker nodes.
data "template_cloudinit_config" "worker" {
  count = var.worker_count
  gzip = true
  base64_encode = true
  part {
    content_type = "text/cloud-config"
    content = <<-EOF
      #cloud-config
      hostname: w${count.index}
      users:
        - name: vagrant
          passwd: '$6$rounds=4096$NQ.EmIrGxn$rTvGsI3WIsix9TjWaDfKrt9tm3aa7SX7pzB.PSjbwtLbsplk1HsVzIrZbXwQNce6wmeJXhCq9YFJHDx9bXFHH.'
          lock_passwd: false
          ssh-authorized-keys:
            - ${file("~/.ssh/id_rsa.pub")}
      runcmd:
        - sed -i '/vagrant insecure public key/d' /home/vagrant/.ssh/authorized_keys
        # make sure the vagrant account is not expired.
        # NB this is needed when the base image expires the vagrant account.
        - usermod --expiredate '' vagrant
      EOF
  }
}

resource "vsphere_folder" "folder" {
  path = var.vsphere_folder
  type = "vm"
  datacenter_id = data.vsphere_datacenter.datacenter.id
}

# see https://www.terraform.io/docs/providers/vsphere/r/virtual_machine.html
resource "vsphere_virtual_machine" "controller" {
  count = var.controller_count
  folder = vsphere_folder.folder.path
  name = "${var.prefix}_c${count.index}"
  guest_id = data.vsphere_virtual_machine.ubuntu_template.guest_id
  num_cpus = 4
  num_cores_per_socket = 4
  memory = 4*1024
  enable_disk_uuid = true # NB the VM must have disk.EnableUUID=1 for the k8s persistent storage.
  resource_pool_id = data.vsphere_compute_cluster.compute_cluster.resource_pool_id
  datastore_id = data.vsphere_datastore.datastore.id
  scsi_type = data.vsphere_virtual_machine.ubuntu_template.scsi_type
  disk {
    unit_number = 0
    label = "os"
    size = max(data.vsphere_virtual_machine.ubuntu_template.disks.0.size, 15) # 15 GB minimum.
    eagerly_scrub = data.vsphere_virtual_machine.ubuntu_template.disks.0.eagerly_scrub
    thin_provisioned = data.vsphere_virtual_machine.ubuntu_template.disks.0.thin_provisioned
  }
  network_interface {
    network_id = data.vsphere_network.network.id
    adapter_type = data.vsphere_virtual_machine.ubuntu_template.network_interface_types.0
  }
  clone {
    template_uuid = data.vsphere_virtual_machine.ubuntu_template.id
  }
  # NB this extra_config data ends-up inside the VM .vmx file and will be
  #    exposed by cloud-init-vmware-guestinfo as a cloud-init datasource.
  extra_config = {
    "guestinfo.userdata" = data.template_cloudinit_config.controller[count.index].rendered
    "guestinfo.userdata.encoding" = "gzip+base64"
  }
  connection {
    type = "ssh"
    user = "vagrant"
    host = self.default_ip_address
    private_key = file("~/.ssh/id_rsa")
  }
  provisioner "file" {
    source = "containerd-config.toml.patch"
    destination = "/tmp/containerd-config.toml.patch"
  }
  provisioner "file" {
    source = "provision.sh"
    destination = "/tmp/provision.sh"
  }
  # NB in a non-test environment, all the dependencies should already be in
  #    the base image and we would not needed to ad-hoc provision anything
  #    here.
  provisioner "remote-exec" {
    inline = [
      "sudo bash /tmp/provision.sh"
    ]
  }
  lifecycle {
    ignore_changes = [
      # ignore changes to the disks because these will be modified by the
      # vSphere Cloud Provider driver while attaching Persistent Volume
      # Hard Disks.
      # see https://github.com/hashicorp/terraform-provider-vsphere/issues/1028
      disk,
    ]
  }
}

# see https://www.terraform.io/docs/providers/vsphere/r/virtual_machine.html
resource "vsphere_virtual_machine" "worker" {
  count = var.worker_count
  folder = vsphere_folder.folder.path
  name = "${var.prefix}_w${count.index}"
  guest_id = data.vsphere_virtual_machine.ubuntu_template.guest_id
  num_cpus = 4
  num_cores_per_socket = 4
  memory = 8*1024
  enable_disk_uuid = true # NB the VM must have disk.EnableUUID=1 for the k8s persistent storage.
  resource_pool_id = data.vsphere_compute_cluster.compute_cluster.resource_pool_id
  datastore_id = data.vsphere_datastore.datastore.id
  scsi_type = data.vsphere_virtual_machine.ubuntu_template.scsi_type
  disk {
    unit_number = 0
    label = "os"
    size = max(data.vsphere_virtual_machine.ubuntu_template.disks.0.size, 15) # 15 GB minimum.
    eagerly_scrub = data.vsphere_virtual_machine.ubuntu_template.disks.0.eagerly_scrub
    thin_provisioned = data.vsphere_virtual_machine.ubuntu_template.disks.0.thin_provisioned
  }
  network_interface {
    network_id = data.vsphere_network.network.id
    adapter_type = data.vsphere_virtual_machine.ubuntu_template.network_interface_types.0
  }
  clone {
    template_uuid = data.vsphere_virtual_machine.ubuntu_template.id
  }
  # NB this extra_config data ends-up inside the VM .vmx file and will be
  #    exposed by cloud-init-vmware-guestinfo as a cloud-init datasource.
  extra_config = {
    "guestinfo.userdata" = data.template_cloudinit_config.worker[count.index].rendered
    "guestinfo.userdata.encoding" = "gzip+base64"
  }
  connection {
    type = "ssh"
    user = "vagrant"
    host = self.default_ip_address
    private_key = file("~/.ssh/id_rsa")
  }
  provisioner "file" {
    source = "containerd-config.toml.patch"
    destination = "/tmp/containerd-config.toml.patch"
  }
  provisioner "file" {
    source = "provision.sh"
    destination = "/tmp/provision.sh"
  }
  # NB in a non-test environment, all the dependencies should already be in
  #    the base image and we would not needed to ad-hoc provision anything
  #    here.
  provisioner "remote-exec" {
    inline = [
      "sudo bash /tmp/provision.sh"
    ]
  }
  lifecycle {
    ignore_changes = [
      # ignore changes to the disks because these will be modified by the
      # vSphere Cloud Provider driver while attaching Persistent Volume
      # Hard Disks.
      # see https://github.com/hashicorp/terraform-provider-vsphere/issues/1028
      disk,
    ]
  }
}

resource "rke_cluster" "example" {
  kubernetes_version = var.kubernetes_version
  dynamic "nodes" {
    for_each = vsphere_virtual_machine.controller
    iterator = it
    content {
      address = it.value.default_ip_address
      user = "vagrant"
      role = ["controlplane", "etcd"]
      ssh_key = file("~/.ssh/id_rsa")
    }
  }
  dynamic "nodes" {
    for_each = vsphere_virtual_machine.worker
    iterator = it
    content {
      address = it.value.default_ip_address
      user = "vagrant"
      role = ["worker"]
      ssh_key = file("~/.ssh/id_rsa")
    }
  }
  upgrade_strategy {
    drain = true
    max_unavailable_worker = "20%"
  }
  # see https://rancher.com/docs/rke/latest/en/config-options/cloud-providers/vsphere/
  # see https://rancher.com/docs/rke/latest/en/config-options/cloud-providers/vsphere/config-reference/
  # see https://rancher.com/docs/rancher/v2.5/en/cluster-admin/volumes-and-storage/examples/vsphere/
  cloud_provider {
    name = "vsphere"
    vsphere_cloud_provider {
      global {
        insecure_flag = true
      }
      virtual_center {
        name = var.vsphere_server
        user = var.vsphere_user
        password = var.vsphere_password
        datacenters = var.vsphere_datacenter
      }
      workspace {
        server = var.vsphere_server
        datacenter = var.vsphere_datacenter
        folder = "${vsphere_folder.folder.type}/${vsphere_folder.folder.path}"
        # NB vSphere will create a folder named "kubevols" inside this
        #    datastore. the actual k8s volumes .vmdk will be stored as, e.g.,
        #    kubernetes-dynamic-pvc-5ed4b014-7db0-425e-97d4-8ff8dd0cd0e1.vmdk.
        default_datastore = var.vsphere_datastore
      }
    }
  }
}

output "rke_state" {
  sensitive = true
  value = rke_cluster.example.rke_state
}

output "kubeconfig" {
  sensitive = true
  value = rke_cluster.example.kube_config_yaml
}
