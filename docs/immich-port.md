# Migrating Immich from Raspberry Pi to sweet

## Overview

Transfer all Immich data (photos, videos, albums, face recognition, user accounts)
from the Pi to the NixOS server.

## Steps

### 1. Export database on the Pi (before unplugging)

```bash
sudo -u postgres pg_dump immich > /tmp/immich-db-backup.sql
```

Copy the backup to the Pi's data drive so it travels with the HDD:

```bash
cp /tmp/immich-db-backup.sql /path/to/immich/data/
```

### 2. Plug the Pi's HDD into the server

```bash
# Find the drive
lsblk

# Mount it
sudo mkdir -p /mnt/pi-drive
sudo mount /dev/sdX1 /mnt/pi-drive
ls /mnt/pi-drive
```

### 3. Copy media files

```bash
sudo rsync -av --progress /mnt/pi-drive/path/to/immich/upload/ /mnt/data1/Media/Photos/
sudo chown -R immich:share /mnt/data1/Media/Photos/
```

### 4. Stop Immich on the server

```bash
sudo systemctl stop immich-server immich-machine-learning
```

### 5. Import the database

```bash
# Drop the empty database created by the fresh install
sudo -u postgres dropdb immich
sudo -u postgres createdb -O immich immich

# Import the Pi's database
sudo -u postgres psql immich < /mnt/pi-drive/path/to/immich-db-backup.sql
```

### 6. Start Immich

```bash
sudo systemctl start immich-server immich-machine-learning
```

### 7. Verify

Open `https://photos.demasi.dev` — all photos, albums, faces, and users should be there.

### 8. Cleanup

```bash
sudo umount /mnt/pi-drive
sudo rmdir /mnt/pi-drive
```

## Notes

- Find where Immich stores data on the Pi: check `docker compose` config or
  `/var/lib/immich/` or wherever the Pi's Immich was configured
- The Pi's HDD filesystem needs to be readable by Linux (ext4 works, NTFS needs ntfs-3g)
- If the Pi used a different Immich version, you may need to let Immich run migrations
  after importing — it handles this automatically on startup
