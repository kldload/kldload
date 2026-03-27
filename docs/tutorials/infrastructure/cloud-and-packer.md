# Cloud Deployment & Packer Integration

kldload produces disk images. Packer consumes disk images. Terraform deploys them. The three tools chain together naturally — kldload handles the hard part (ZFS on root, boot environments, DKMS), and your existing cloud tooling handles the rest.

The key insight: **use kldload Core as your Packer base image.** You get ZFS on root with zero manual setup. Then Packer adds your application layer on top. Terraform deploys the result. Your entire stack runs on ZFS with boot environments, snapshots, and compression — and you didn't have to change your cloud workflow.

---

## The pipeline

```
kldload (build)
  │
  │  EDITION=core or PROFILE=core
  │  produces: qcow2 / raw / VHD / VMDK / OVA
  │
  ▼
Packer (customize)
  │
  │  your provisioners: Ansible, shell, Chef, etc.
  │  adds: your app, config, users, services
  │
  ▼
Terraform (deploy)
  │
  │  launches instances from the Packer AMI/image
  │  manages infrastructure lifecycle
  │
  ▼
Production
  ZFS on root + boot environments + your app
```

---

## Step 1: Build a kldload Core image

### Option A: Build from the ISO (full control)

```bash
# Clone kldload
git clone https://github.com/kldload/kldload.git
cd kldload

# Build the ISO
./deploy.sh clean
./deploy.sh builder-image
PROFILE=desktop ./deploy.sh build

# Create a VM and install with Core profile
ISO=$(ls -t live-build/output/*.iso | head -1)
virt-install \
  --name kldload-base \
  --ram 4096 --vcpus 4 \
  --disk path=/var/lib/libvirt/images/kldload-base.qcow2,size=40,format=qcow2 \
  --cdrom "$ISO" \
  --os-variant centos-stream9 \
  --boot uefi \
  --noautoconsole

# Install via web UI or unattended:
# Pick Core profile, your distro, minimal config
# After install completes, shut down the VM
virsh shutdown kldload-base
```

### Option B: Unattended install (automated)

```bash
# Create an answers file for Core
cat > /tmp/core-answers.env << 'EOF'
KLDLOAD_DISTRO=debian
KLDLOAD_DISK=/dev/vda
KLDLOAD_HOSTNAME=base-image
KLDLOAD_USERNAME=admin
KLDLOAD_PASSWORD=packer-temp
KLDLOAD_PROFILE=core
KLDLOAD_NET_METHOD=dhcp
KLDLOAD_TIMEZONE=UTC
EOF

# Boot the ISO, install unattended
virt-install \
  --name kldload-base \
  --ram 4096 --vcpus 4 \
  --disk path=/var/lib/libvirt/images/kldload-base.qcow2,size=40,format=qcow2 \
  --cdrom "$ISO" \
  --os-variant centos-stream9 \
  --boot uefi \
  --noautoconsole --wait

# The VM installs and shuts down automatically
```

### Option C: Export from an existing install

If you already have a kldload system running:

```bash
# On the running system
kexport qcow2    # → kldload-export-YYYYMMDD-HHMMSS.qcow2
kexport raw      # → for AWS import
kexport vhd      # → for Azure
kexport vmdk     # → for VMware
```

---

## Step 2: Use kldload as Packer base image

### Packer with QEMU builder (local)

```hcl
# kldload-base.pkr.hcl

packer {
  required_plugins {
    qemu = {
      source  = "github.com/hashicorp/qemu"
      version = "~> 1"
    }
  }
}

source "qemu" "kldload" {
  # Use the kldload Core qcow2 as the base — ZFS on root is already done
  disk_image       = true
  iso_url          = "/var/lib/libvirt/images/kldload-base.qcow2"
  iso_checksum     = "none"
  output_directory = "output"
  vm_name          = "my-app-server.qcow2"

  format         = "qcow2"
  disk_size      = "40G"
  memory         = 4096
  cpus           = 4
  headless       = true

  # UEFI boot (kldload uses UEFI)
  qemuargs = [
    ["-bios", "/usr/share/OVMF/OVMF_CODE.fd"],
  ]

  ssh_username = "admin"
  ssh_password = "packer-temp"
  ssh_timeout  = "10m"

  shutdown_command = "sudo poweroff"
}

build {
  sources = ["source.qemu.kldload"]

  # Your provisioners — this is where you add your stuff
  provisioner "shell" {
    inline = [
      # ZFS is already on root — use it
      "sudo zfs snapshot rpool@pre-packer",

      # Install your application
      "sudo apt-get update",
      "sudo apt-get install -y nginx postgresql redis",

      # Or on CentOS/Fedora/RHEL/Rocky:
      # "sudo dnf install -y nginx postgresql redis",

      # Or on Arch:
      # "sudo pacman -S --noconfirm nginx postgresql redis",

      # Configure your app
      "sudo systemctl enable nginx postgresql redis",

      # Create ZFS datasets for your data
      "sudo zfs create -o mountpoint=/srv/app rpool/srv/app",
      "sudo zfs create -o mountpoint=/srv/db -o recordsize=8k rpool/srv/db",

      # Snapshot after provisioning — rollback point
      "sudo zfs snapshot rpool@post-packer",
    ]
  }

  # Or use Ansible
  provisioner "ansible" {
    playbook_file = "playbooks/app-server.yml"
  }

  # Clean up for image distribution
  provisioner "shell" {
    inline = [
      "sudo cloud-init clean 2>/dev/null || true",
      "sudo truncate -s 0 /etc/machine-id",
      "sudo rm -f /etc/ssh/ssh_host_*",
      "sudo rm -f /home/admin/.bash_history",
      "sudo sync",
    ]
  }
}
```

```bash
packer build kldload-base.pkr.hcl
# Output: output/my-app-server.qcow2
```

### What Packer gets for free (from kldload Core)

You didn't configure any of this — kldload Core did it during install:

- ZFS on root with proper ashift, compression, acltype
- ZFSBootMenu bootloader with boot environment support
- Deterministic dataset hierarchy (`/home`, `/var/log`, `/srv` as separate datasets)
- DKMS-built ZFS module for the installed kernel
- EFI boot chain (shim + GRUB)
- Hostid configured for ZFS

Your Packer provisioner just adds your application on top. If you used the `free` or `server` profile instead of `core`, you'd also get the `k*` tools, sanoid, and the web UI.

---

## Step 3: Deploy to AWS

### Import the Packer output as an AMI

```bash
# Convert qcow2 to raw (AWS requires raw for import)
qemu-img convert -f qcow2 -O raw output/my-app-server.qcow2 output/my-app-server.raw

# Upload to S3
aws s3 cp output/my-app-server.raw s3://my-images/my-app-server.raw

# Import as AMI
aws ec2 import-image \
  --disk-containers "Format=RAW,UserBucket={S3Bucket=my-images,S3Key=my-app-server.raw}" \
  --description "My app on kldload Core (ZFS on root)" \
  --boot-mode uefi

# Wait for import
aws ec2 describe-import-image-tasks --query 'ImportImageTasks[*].[ImportTaskId,Status,StatusMessage]' --output table

# Once complete, get the AMI ID
AMI_ID=$(aws ec2 describe-import-image-tasks --query 'ImportImageTasks[0].ImageId' --output text)
```

### Or use Packer's Amazon builder directly

```hcl
# aws-kldload.pkr.hcl

source "amazon-ebs" "kldload" {
  # Start from the imported kldload AMI
  source_ami   = "ami-xxxxxxxxxxxx"  # your imported kldload Core AMI
  instance_type = "t3.medium"
  region        = "us-west-2"
  ssh_username  = "admin"
  ami_name      = "my-app-{{timestamp}}"

  launch_block_device_mappings {
    device_name = "/dev/sda1"
    volume_size = 40
    volume_type = "gp3"
  }
}

build {
  sources = ["source.amazon-ebs.kldload"]

  provisioner "shell" {
    inline = [
      "sudo zfs snapshot rpool@pre-provision",
      "sudo apt-get update && sudo apt-get install -y nginx",
      "sudo zfs snapshot rpool@post-provision",
    ]
  }
}
```

```bash
packer build aws-kldload.pkr.hcl
# Output: AMI with ZFS on root + your app
```

---

## Step 4: Deploy with Terraform

```hcl
# main.tf

provider "aws" {
  region = "us-west-2"
}

data "aws_ami" "kldload_app" {
  most_recent = true
  owners      = ["self"]

  filter {
    name   = "name"
    values = ["my-app-*"]
  }
}

resource "aws_instance" "app" {
  count         = 3
  ami           = data.aws_ami.kldload_app.id
  instance_type = "t3.medium"

  root_block_device {
    volume_size = 40
    volume_type = "gp3"
  }

  tags = {
    Name = "app-server-${count.index + 1}"
  }
}

output "instance_ips" {
  value = aws_instance.app[*].public_ip
}
```

```bash
terraform init
terraform apply
# 3 instances with ZFS on root, boot environments, your app
```

---

## Azure deployment

### Export and upload

```bash
# Export as VHD (Azure requires fixed-size VHD)
kexport vhd

# Upload to Azure
az storage blob upload \
  --account-name myaccount \
  --container-name images \
  --name kldload-core.vhd \
  --type page \
  --file kldload-export-*.vhd

# Create image
az image create \
  --resource-group mygroup \
  --name kldload-core \
  --os-type Linux \
  --source https://myaccount.blob.core.windows.net/images/kldload-core.vhd
```

### Terraform for Azure

```hcl
resource "azurerm_linux_virtual_machine" "app" {
  name                = "app-server"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  size                = "Standard_B2ms"
  admin_username      = "admin"

  source_image_id = azurerm_image.kldload.id

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 40
  }

  admin_ssh_key {
    username   = "admin"
    public_key = file("~/.ssh/id_rsa.pub")
  }
}
```

---

## Proxmox deployment with Terraform

```hcl
# Proxmox provider
provider "proxmox" {
  pm_api_url  = "https://10.100.10.225:8006/api2/json"
  pm_user     = "root@pam!root"
  pm_password = var.proxmox_token
}

resource "proxmox_vm_qemu" "app" {
  count       = 3
  name        = "app-${count.index + 1}"
  target_node = "fiend"
  clone       = "kldload-core-template"

  cores   = 4
  memory  = 4096
  scsihw  = "virtio-scsi-single"
  boot    = "order=scsi0"

  disk {
    size    = "40G"
    type    = "scsi"
    storage = "local-zfs"
  }

  network {
    model  = "virtio"
    bridge = "vmbr0"
  }
}
```

---

## The point

You don't have to choose between kldload and your existing tooling. kldload produces the base image — the part that's hard to automate (ZFS on root, DKMS, boot environments, bootloader). Packer adds your application layer. Terraform deploys it.

**Without kldload:** You spend hours manually partitioning, building ZFS DKMS, configuring initramfs, and praying the bootloader works — for every base image, on every platform.

**With kldload Core:** You run one install, export a qcow2, point Packer at it, and your entire fleet runs on ZFS with boot environments. The hard part is a 2-minute install. The rest is your existing workflow, unchanged.

```
Traditional:          manual ZFS setup (2 hours) → Packer → Terraform
With kldload:         kldload Core (2 minutes) → Packer → Terraform
```
