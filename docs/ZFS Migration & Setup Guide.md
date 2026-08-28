# ZFS Migration & Setup Guide (Debian Homelab)

## 1. Scenario Overview

* Source: ext4 disk (~300GB data)
* Target: 2×1TB disks → ZFS mirror
* Temporary storage: NVMe (free space available)

---

## 2. Data Migration Flow

### Step 1: Copy ext4 → NVMe

```bash
rsync -aHAX --info=progress2 /mnt/old/ /nvme-temp/
```

**Explanation:**

* `-a` → archive (preserves permissions, timestamps, symlinks)
* `-H` → preserves hardlinks
* `-A` → preserves ACLs
* `-X` → preserves extended attributes
* `--info=progress2` → shows overall progress

---

### Step 2: Create ZFS pool

```bash
sudo apt install zfsutils-linux
sudo zpool create twins /dev/sdb
```

**Explanation:**

* `zpool create` → creates ZFS pool
* `twins` → pool name (mounts as `/twins`)
* `/dev/sdb` → disk used (WILL BE ERASED)

---

### Step 3: Copy NVMe → ZFS

```bash
rsync -aHAX --info=progress2 /nvme-temp/ /twins/
```

---

### Step 4: Create mirror (attach second disk)

```bash
sudo wipefs -a /dev/sda
sudo zpool attach twins /dev/sdb /dev/sda
```

**Explanation:**

* `wipefs -a` → removes all filesystem signatures
* `zpool attach` → converts single disk → mirror

  * first disk = existing (`sdb`)
  * second disk = new (`sda`)

---

### Step 5: Monitor resilver

```bash
zpool status
```

---

## 3. rsync Behavior (Important)

### Copy contents vs folder

```bash
rsync -avh /src/ /dest/
```

→ copies **inside src**

```bash
rsync -avh /src /dest/
```

→ copies **src folder itself**

---

### Move using rsync

```bash
rsync -aHAX /src/ /dest/ && rm -rf /src/
```

---

## 4. ZFS Concepts

### Resilver vs RAID rebuild

* ZFS:

  * copies only **used data**
  * faster and safer
* RAID:

  * copies **entire disk**
  * slower and higher risk

---

### Check health

```bash
zpool status
zpool status -x
```

---

### Scrub (data integrity check)

```bash
sudo zpool scrub twins
```

---

## 5. Scrub Automation

### Cron (monthly – 1st Sunday 3AM)

```bash
sudo crontab -e
```

```bash
0 3 1-7 * 0 zpool scrub twins
```

---

### systemd timer (recommended)

#### Service

```bash
sudo nano /etc/systemd/system/zfs-scrub.service
```

```
[Unit]
Description=ZFS Scrub

[Service]
Type=oneshot
ExecStart=/sbin/zpool scrub twins
```

#### Timer

```bash
sudo nano /etc/systemd/system/zfs-scrub.timer
```

```
[Unit]
Description=Monthly ZFS Scrub

[Timer]
OnCalendar=Sun *-*-01..07 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

#### Enable

```bash
sudo systemctl enable --now zfs-scrub.timer
```

---

## 6. ZFS Mounting (No fstab)

* ZFS auto-mounts datasets
* Do NOT use `/etc/fstab`

### Check mountpoints

```bash
zfs get mountpoint
```

### Set custom mountpoint

```bash
sudo zfs set mountpoint=/data twins
```

---

## 7. Export / Import (Pool Handling)

### Export

```bash
sudo zpool export twins
```

* safely unmounts pool

### Import

```bash
sudo zpool import twins
```

* re-attaches pool

---

## 8. Useful Commands

### Check disks

```bash
lsblk
```

### Check pool

```bash
zpool list
zpool status
```

### Show full device paths

```bash
zpool status -P
```

---

## 9. Best Practices

* Always use rsync with:

```bash
rsync -aHAX
```

* Run scrub monthly
* Monitor:

```bash
zpool status
```

* Mirror ≠ backup

  * deletion affects both disks

---

## 10. Recommended Improvements

### Use stable disk IDs

```bash
ls -l /dev/disk/by-id/
```

### Example

```bash
zpool create twins /dev/disk/by-id/ata-XXXX
```

---

## 11. Post Setup Checklist

```bash
zpool status
zfs list
lsmod | grep zfs
```

---

## Final Notes

* ZFS is safer than RAID due to checksums
* Resilver is faster than RAID rebuild
* Always keep external backup for critical data

---

If you want, I can extend this with:

* ZFS tuning (compression, recordsize)
* snapshots + retention policy (very useful next step)
