# Secure Boot and Encryption

kldload supports Secure Boot via MOK (Machine Owner Key) enrollment and ZFS native encryption (AES-256-GCM). Both work on CentOS/RHEL and Debian.

---

## ZFS encryption

### Enable during install

Set `KLDLOAD_ZFS_ENCRYPT=1` in the answers file or select encryption in the web UI. The installer creates the pool with:

- `encryption=aes-256-gcm`
- `keyformat=passphrase`
- `keylocation=prompt`

You'll enter a passphrase at every boot.

### Verify encryption status

```bash
zfs get encryption,keystatus rpool
```

```
NAME   PROPERTY     VALUE
rpool  encryption   aes-256-gcm
rpool  keystatus    available
```

### Encrypt individual datasets (on an unencrypted pool)

You don't have to encrypt the whole pool. Encrypt only sensitive data:

```bash
# Create an encrypted dataset
zfs create -o encryption=aes-256-gcm \
           -o keyformat=passphrase \
           rpool/srv/secrets
# Enter passphrase when prompted

# Create with a key file instead of passphrase
dd if=/dev/urandom of=/root/.zfs-key bs=32 count=1
chmod 600 /root/.zfs-key
zfs create -o encryption=aes-256-gcm \
           -o keyformat=raw \
           -o keylocation=file:///root/.zfs-key \
           rpool/srv/automated-secrets
```

### Lock and unlock

```bash
# Lock (unmount and unload key)
zfs unmount rpool/srv/secrets
zfs unload-key rpool/srv/secrets

# Unlock
zfs load-key rpool/srv/secrets     # prompts for passphrase
zfs mount rpool/srv/secrets
```

### Change passphrase

```bash
zfs change-key rpool
# Enter current passphrase, then new passphrase
```

---

## Secure Boot with MOK

kldload ISOs boot with Secure Boot via the shim bootloader (same chain as Fedora/Ubuntu). After install, DKMS kernel modules (ZFS, NVIDIA) need signing.

### How it works

1. kldload installs the shim EFI binary (`BOOTX64.EFI`) which is signed by Microsoft's UEFI CA
2. Shim loads GRUB2 or ZFSBootMenu
3. The kernel is signed by the distro vendor (CentOS/Debian)
4. Third-party kernel modules (ZFS, NVIDIA) are signed with a MOK key that kldload generates during install

### Check Secure Boot status

```bash
mokutil --sb-state
# SecureBoot enabled/disabled

# List enrolled MOK keys
mokutil --list-enrolled
```

### The MOK key

kldload stores the MOK key pair at:

```
/var/lib/kldload/mok/MOK.priv    # private key (600 permissions)
/var/lib/kldload/mok/MOK.der     # public certificate (enrolled in firmware)
```

### Sign a kernel module manually

If you install a new DKMS module (or the automatic signing fails):

```bash
# Find the module
modinfo -n zfs
# /lib/modules/5.14.0-xxx/extra/zfs.ko.xz

# Sign it
/usr/src/kernels/$(uname -r)/scripts/sign-file sha256 \
  /var/lib/kldload/mok/MOK.priv \
  /var/lib/kldload/mok/MOK.der \
  /lib/modules/$(uname -r)/extra/zfs.ko.xz

# Verify the signature
modinfo zfs | grep signer
```

### Enroll a new MOK key

If you generated a new key and need to enroll it in the firmware:

```bash
# Stage the key for enrollment
mokutil --import /var/lib/kldload/mok/MOK.der
# Enter a one-time password

# Reboot — the shim MOK manager will prompt you to enroll the key
reboot
```

At the blue MOK Manager screen:
1. Select "Enroll MOK"
2. Select "Continue"
3. Enter the one-time password you set
4. Select "Reboot"

### DKMS auto-signing

`kupgrade` automatically checks and re-signs DKMS modules after kernel upgrades:

```bash
# Manual check
dkms status

# Rebuild and sign for current kernel
dkms autoinstall
```

---

## Full disk encryption + Secure Boot together

This is the most secure configuration — encrypted data at rest with verified boot chain:

1. Install with `KLDLOAD_ZFS_ENCRYPT=1` and Secure Boot enabled in firmware
2. kldload generates MOK key, creates encrypted pool, signs ZFS module
3. At boot: firmware verifies shim → shim verifies GRUB → GRUB loads kernel → ZFS prompts for passphrase

### Automating unlock with Clevis (TPM2)

To avoid typing the passphrase at every boot, bind the encryption key to the TPM:

```bash
# CentOS/RHEL
dnf install -y clevis clevis-luks clevis-tpm2

# Debian
apt install -y clevis clevis-tpm2
```

> Note: ZFS native encryption doesn't integrate directly with Clevis the way LUKS does. The kldload firstboot service stages the passphrase at `/etc/kldload/zfs-passphrase` for potential Clevis sealing. This is an area of active development.

---

## Troubleshooting

```bash
# Module won't load — signature issue
dmesg | grep -i "module verification failed"
# Fix: re-sign the module (see above)

# MOK key not enrolled
mokutil --test-key /var/lib/kldload/mok/MOK.der
# "is not enrolled" → need to run mokutil --import and reboot

# Encrypted pool won't import
zpool import -a    # prompts for passphrase
zfs load-key -a    # load all keys
zfs mount -a       # mount everything

# Forgot the passphrase
# No recovery possible with ZFS native encryption.
# If you have a backup (zfs send), restore from that.
# This is why boot environment snapshots matter — they're part of the encrypted pool.
```
