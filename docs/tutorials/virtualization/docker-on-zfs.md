# Docker and Podman on ZFS

kldload installs on ZFS by default. Docker and Podman both work well on ZFS — container layers map naturally to ZFS datasets, giving you snapshots, clones, and compression for free.

---

## Install Docker

### CentOS/RHEL

```bash
# Add Docker CE repo
dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo

# Install
dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# Enable and start
systemctl enable --now docker
```

### Debian

```bash
# Add Docker GPG key and repo
apt-get install -y ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian trixie stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

systemctl enable --now docker
```

---

## Configure Docker to use the ZFS storage driver

Docker auto-detects ZFS if `/var/lib/docker` is on a ZFS dataset. On kldload systems it usually is, but let's make it explicit.

### Create a dedicated dataset for Docker

```bash
# Create a dataset with optimized settings for container layers
zfs create -o mountpoint=/var/lib/docker \
           -o compression=lz4 \
           -o atime=off \
           -o recordsize=128k \
           rpool/docker
```

### Verify Docker is using ZFS

```bash
docker info | grep "Storage Driver"
# Should show: Storage Driver: zfs
```

If it shows `overlay2` instead, Docker started before the dataset was created. Restart:

```bash
systemctl stop docker
# Make sure /var/lib/docker is empty and mounted on ZFS
rm -rf /var/lib/docker/*
systemctl start docker
docker info | grep "Storage Driver"
```

### What this gives you

With the ZFS storage driver, every Docker image layer and container filesystem is a ZFS dataset:

```bash
# See Docker's ZFS datasets
zfs list -r rpool/docker
```

```
NAME                                                          USED  AVAIL  REFER  MOUNTPOINT
rpool/docker                                                  2.1G  35.0G    24K  /var/lib/docker
rpool/docker/c3f5...                                          156M  35.0G   156M  legacy
rpool/docker/a7e2...                                          89M   35.0G    89M  legacy
```

Benefits:
- **Instant snapshots** of any container's filesystem
- **CoW clones** — spinning up 10 containers from the same image uses near-zero extra space
- **Compression** — lz4 typically saves 30–50% on container layers
- **No overlay filesystem overhead** — direct ZFS dataset access

---

## Podman on ZFS (rootless)

Podman works the same way. On kldload systems, Podman is available without installing Docker:

```bash
# CentOS/RHEL — already in the repos
dnf install -y podman

# Debian
apt-get install -y podman
```

For rootless Podman, create a dataset under the user's home:

```bash
# As root, create the dataset
zfs create -o mountpoint=/home/admin/.local/share/containers \
           -o compression=lz4 \
           rpool/home/admin/containers
chown admin:admin /home/admin/.local/share/containers
```

Now rootless Podman uses ZFS storage automatically.

---

## Snapshot a running container

Since Docker layers are ZFS datasets, you can snapshot at the ZFS level — faster and more flexible than `docker commit`:

```bash
# Find the container's ZFS dataset
CONTAINER_ID=$(docker inspect --format '{{.GraphDriver.Data.Dataset}}' my-container)

# Snapshot it
zfs snapshot "${CONTAINER_ID}@before-migration"

# Roll back if something breaks
zfs rollback "${CONTAINER_ID}@before-migration"
```

Or use the kldload tools:

```bash
# Snapshot everything under /var/lib/docker
ksnap /var/lib/docker

# List snapshots
ksnap list
```

---

## Docker Compose on ZFS datasets

For persistent data (databases, file stores), create dedicated ZFS datasets instead of using Docker volumes:

```bash
# Create datasets for a PostgreSQL + Redis stack
zfs create -o mountpoint=/srv/myapp rpool/srv/myapp
zfs create -o mountpoint=/srv/myapp/postgres -o recordsize=8k rpool/srv/myapp/postgres
zfs create -o mountpoint=/srv/myapp/redis rpool/srv/myapp/redis
```

> `recordsize=8k` matches PostgreSQL's 8KB page size for optimal I/O.

Then bind-mount in your compose file:

```yaml
# docker-compose.yml
services:
  postgres:
    image: postgres:16
    volumes:
      - /srv/myapp/postgres:/var/lib/postgresql/data
    environment:
      POSTGRES_PASSWORD: changeme

  redis:
    image: redis:7
    volumes:
      - /srv/myapp/redis:/data
```

```bash
docker compose up -d
```

### Backup the entire stack

```bash
# Recursive snapshot — catches postgres AND redis datasets
zfs snapshot -r rpool/srv/myapp@backup-$(date +%Y%m%d)

# List backups
zfs list -t snapshot -r rpool/srv/myapp
```

### Clone for dev/test

```bash
# Instant clone of production data for testing
zfs clone rpool/srv/myapp/postgres@backup-20260321 rpool/srv/myapp-test/postgres

# Run a test instance on the clone
docker run -d --name pg-test \
  -v /srv/myapp-test/postgres:/var/lib/postgresql/data \
  -p 5433:5432 \
  postgres:16
```

The clone starts at near-zero space and only grows as the test instance writes new data. Delete it when done:

```bash
docker rm -f pg-test
zfs destroy rpool/srv/myapp-test/postgres
```

---

## Recommended ZFS properties for Docker workloads

| Property | Value | Why |
|----------|-------|-----|
| `compression` | `lz4` | Fast, saves 30–50% on container layers |
| `atime` | `off` | Containers don't need access time tracking |
| `recordsize` | `128k` | Good default for mixed container I/O |
| `recordsize` | `8k` | For PostgreSQL data directories |
| `recordsize` | `16k` | For MySQL/MariaDB data directories |
| `logbias` | `throughput` | For sequential write workloads (logs, streams) |
| `sync` | `standard` | Keep `standard` unless you know you can afford data loss |

---

## Limits and gotchas

- **ZFS memory usage**: Docker on ZFS means the ARC cache competes with container memory. On memory-constrained systems, cap the ARC:
  ```bash
  echo "options zfs zfs_arc_max=4294967296" > /etc/modprobe.d/zfs-arc.conf
  ```
- **Dataset count**: Each image layer creates a ZFS dataset. Pulling many images can create thousands of datasets. This is fine — ZFS handles it — but `zfs list` output gets long. Use `zfs list -r rpool/docker -o name,used,refer -S used | head -20` to see the biggest consumers.
- **Snapshot before pruning**: Before running `docker system prune`, take a snapshot so you can recover if you prune too aggressively:
  ```bash
  ksnap /var/lib/docker
  docker system prune -af
  ```
