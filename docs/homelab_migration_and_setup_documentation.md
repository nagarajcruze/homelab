# HomeLab Setup and Migration Documentation

Source notes: fileciteturn0file0

## 1. NVIDIA GPU Setup for Docker

Reference:
- urlNVIDIA Container Toolkit Docshttps://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html
- urlProxmox Forum Discussionhttps://forum.proxmox.com/threads/proxmox-9-1-nvidia-drivers-desktop-gui.178307/

### Add NVIDIA Container Toolkit Repository

```bash
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
```

- Downloads and installs the NVIDIA repository GPG key.
- Required for secure package verification.

```bash
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
```

- Adds NVIDIA Container Toolkit repository.
- `signed-by=` ensures only the specified GPG key is trusted.

### Install Toolkit

```bash
sudo apt update
sudo apt install -y nvidia-container-toolkit
```

- Installs NVIDIA runtime support for Docker containers.

### Configure Docker Runtime

```bash
sudo nvidia-ctk runtime configure --runtime=docker
```

- Automatically updates Docker configuration for GPU support.
- Creates or updates `/etc/docker/daemon.json`.

```bash
sudo systemctl restart docker
```

- Restarts Docker daemon to apply changes.

### Verify NVIDIA Runtime

```bash
docker info | grep -i runtime
```

Expected output should include:

```text
Runtimes: io.containerd.runc.v2 nvidia runc
```

### Test GPU Inside Docker

```bash
docker run --rm --gpus all nvidia/cuda:12.2.0-runtime-ubuntu22.04 nvidia-smi
```

- Runs temporary CUDA container.
- Verifies GPU passthrough into Docker.

### Create Missing NVIDIA Device Files

```bash
sudo nvidia-modprobe -u -c=0
```

- Creates `/dev/nvidia*` device files if missing.

---

## 2. NVIDIA GPU Access Inside Proxmox LXC Container

### Edit LXC Configuration

```bash
nano /etc/pve/lxc/100.conf
```

Add:

```ini
lxc.mount.entry: /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1 usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1 none bind,ro,create=file
lxc.mount.entry: /usr/lib/x86_64-linux-gnu/libcuda.so.1 usr/lib/x86_64-linux-gnu/libcuda.so.1 none bind,ro,create=file
```

- Mounts required NVIDIA libraries inside the container.
- `ro` mounts as read-only.

### Restart Container

```bash
pct reboot 100
```

### Verify NVIDIA Libraries

```bash
ldconfig -p | grep nvidia
```

### Test GPU Access

```bash
docker run --rm --gpus all nvidia/cuda:12.2.0-runtime-ubuntu22.04 nvidia-smi
```

---

## 3. Intel IOMMU Configuration

### Edit GRUB Configuration

```bash
nano /etc/default/grub
```

Default:

```bash
GRUB_CMDLINE_LINUX_DEFAULT="quiet"
```

For Intel systems:

```bash
GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on"
```

- Enables Intel IOMMU.
- Required for PCI passthrough and advanced virtualization.

### Update GRUB

```bash
sudo update-grub
```

### Reboot System

```bash
sudo reboot
```

### Verify IOMMU

```bash
dmesg | grep -i iommu
```

### Check GPU Devices

```bash
lspci -nn | grep -i vga
lspci -nn | grep -i audio
```

- Displays GPU and HDMI audio PCI devices.

---

## 4. Mount External USB Drive into LXC

### Add Mount Point in Container Config

```bash
nano /etc/pve/lxc/101.conf
```

Add:

```ini
mp1: /mnt/usb,mp=/mnt/usb
```

- Maps host `/mnt/usb` into container.

### Restart Container

```bash
pct reboot 101
```

### Docker Compose Volume Mount

```yaml
volumes:
  - /mnt/usb:/mnt/usb:ro
```

- Mounts USB inside Docker container as read-only.

### Restart Containers

```bash
docker compose down
docker compose up -d
```

### Verify USB Visibility

```bash
docker exec -it immich_server ls /mnt/usb
```

---

## 5. USB Safe Removal and Troubleshooting

### Check Processes Using USB

```bash
lsof +D /mnt/usb
```

or

```bash
fuser -vm /mnt/usb
```

- Shows processes currently using the mount.

### Safe USB Eject

```bash
umount /dev/sdb2 && sync && hdparm -y /dev/sdb && echo 1 > /sys/block/sdb/device/delete
```

Explanation:
- `umount` unmounts filesystem.
- `sync` flushes pending writes.
- `hdparm -y` spins down disk.
- `delete` safely removes device from kernel.

### Simpler USB Power Off

```bash
umount /dev/sdb* && udisksctl power-off -b /dev/sdb
```

or

```bash
umount -l /mnt/usb/
udisksctl power-off -b /dev/sdd
```

### Verify Device Before Unplugging

```bash
lsblk | grep sdb
```

### Install hdparm

```bash
sudo apt install hdparm -y
```

---

## 6. Immich Commands

### Login to Immich CLI

```bash
immich login http://localhost:2283/api <API_KEY>
```

- Authenticates Immich CLI.

### Upload Photos/Videos Recursively

```bash
immich upload ./ --recursive
```

- Uploads current directory recursively.

---

## 7. File Transfer using rsync

```bash
rsync -ah --info=progress2 --no-inc-recursive /mnt/usb/* /mnt/media/movies/
```

Explanation:
- `-a` archive mode.
- `-h` human readable sizes.
- `--info=progress2` shows overall progress.
- `--no-inc-recursive` improves progress reporting.

---

## 8. Netdata Monitoring

### Check Netdata Service

```bash
systemctl status netdata
```

### Test Netdata API

```bash
curl localhost:19999
```

- Verifies Netdata web UI/API is running.

---

## 9. CPU Power Saving Service

### Create Service File

```bash
nano /etc/systemd/system/cpuboost.service
```

Contents:

```ini
[Unit]
Description=Disable CPU boost

[Service]
Type=oneshot
ExecStart=/bin/sh -c "cpupower frequency-set -g powersave && cpupower frequency-set -u 2.4GHz && echo 0 > /sys/devices/system/cpu/cpufreq/boost"

[Install]
WantedBy=multi-user.target
```

Explanation:
- Sets CPU governor to `powersave`.
- Limits max CPU frequency to 2.4GHz.
- Disables CPU turbo boost.

### Enable Service

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now cpuboost
```

### Temporary CPU Frequency Changes

```bash
cpupower frequency-set -u 2.5GHz
cpupower frequency-set -u 2.4GHz
```

---

## 10. Intel VAAPI Hardware Acceleration

### Install VAAPI Drivers

```bash
sudo apt install mesa-va-drivers vainfo
```

### Verify VAAPI

```bash
vainfo
```

- Verifies hardware video acceleration support.

---

## 11. Docker Installation on Debian

### Remove Old Docker Packages

```bash
sudo apt remove docker.io docker-compose docker-doc podman-docker containerd runc
```

### Install Required Packages

```bash
sudo apt update
sudo apt install -y curl wget sudo ca-certificates gnupg
```

### Create Docker Keyrings Directory

```bash
sudo install -m 0755 -d /etc/apt/keyrings
```

### Add Docker GPG Key

```bash
curl -fsSL https://download.docker.com/linux/debian/gpg | \
sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
```

### Set Permissions

```bash
sudo chmod a+r /etc/apt/keyrings/docker.gpg
```

### Add Docker Repository

```bash
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/debian \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
```

### Install Docker

```bash
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

### Verify Docker

```bash
docker version
docker compose version
```

---

## 12. ZFS Commands

### Wipe Existing Filesystem Signatures

```bash
sudo wipefs -a /dev/sda
```

- Removes existing filesystem metadata.

### Attach Disk to Existing Mirror Pool

```bash
sudo zpool attach twins /dev/sdb /dev/sda
```

Explanation:
- `twins` is pool name.
- Adds `/dev/sda` as mirror for `/dev/sdb`.

### Monitor ZFS Status

```bash
zpool status
zpool status -P
```

### Use Persistent Disk IDs

```bash
ls -l /dev/disk/by-id/ | grep sdb
```

- Preferred for stable ZFS device naming.

### Start ZFS Scrub

```bash
sudo zpool scrub twins
```

- Checks pool integrity and repairs corruption.

---

## 13. Btrfs Snapshots

### Create Read-Only Snapshots

```bash
sudo btrfs subvolume snapshot -r / /.snapshots/root-$(date +%F)
sudo btrfs subvolume snapshot -r /opt /.snapshots/opt-$(date +%F)
```

Explanation:
- `-r` creates read-only snapshots.
- `$(date +%F)` appends current date.

---

## 14. Copy Files from List

```bash
cat movies.txt | while IFS= read -r file; do
  cp "$file" /mnt/media/temp/
done
```

Better version:

```bash
while IFS= read -r file; do
  cp "$file" /mnt/media/temp/
done < movies.txt
```

- Reads file paths line-by-line.
- Copies matching files.

---

## 15. Migration Checklist

### Services with Backups

| Service | Backup Required | Notes |
|---|---|---|
| Jellyfin | Yes | `/config/data/backups/` |
| qBittorrent | No config backup needed | Data at `/data/movies` and `/data/downloads` |
| Navidrome | Yes | `data/backup/` |
| Dockge | Usually not needed | Compose files sufficient |
| Grafana | Yes | Export dashboards as `.json` |
| Prometheus | Config only | Data can be regenerated |
| Immich | Yes | Important photos/videos |
| NGINX | Yes | Backup config files |

### No Need to Backup

- Jellyfin artwork/media cache
- Prometheus metrics data
- Navidrome regenerated metadata
- GPU DCGM metrics

### Suggested Migration Steps

1. Backup compose files and configs.
2. Install Debian on OptiPlex.
3. Install Docker and Docker Compose.
4. Restore compose files.
5. Restore application backups.
6. Attach existing storage drives.
7. Start containers.
8. Verify services and GPU access.

---

## 16. Notes About HDD Migration and ZFS

Idea considered:
- Existing 1TB HDD contains Immich photos/videos.
- Wanted to mirror current HDD to another HDD using ZFS.

Important ZFS Notes:
- Replacing disks with larger disks is supported.
- Temporary mirroring can be done using `zpool attach`.
- Resilvering copies data from one disk to another.
- After resilver completes, old disk can be detached.

Useful commands:

```bash
zpool status
zpool attach pool olddisk newdisk
zpool detach pool olddisk
```

---

## 17. Useful Troubleshooting Commands

### Check Mounted Filesystems

```bash
mount | grep usb
```

### Check Disk Usage

```bash
df -h
```

### Check Running Containers

```bash
docker ps
```

### View Container Logs

```bash
docker logs -f <container_name>
```

### Check GPU Usage

```bash
nvidia-smi
```

### Check CPU Frequencies

```bash
cpupower frequency-info
```

