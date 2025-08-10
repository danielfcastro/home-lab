# ARR Ecosystem on Alpine Linux 3.22 (LXC) — Full Setup Guide

This guide explains how to create an **unprivileged LXC container** with **Alpine Linux 3.22** on Proxmox, install Docker and deploy **Prowlarr, Sonarr, Radarr, and Bazarr** via Docker Compose, and configure **Nginx reverse proxy** with **Let's Encrypt** certificates.  
It also covers SSH setup, `netstat` installation, and common pitfalls to avoid.

---

## 0) Creating the LXC from Proxmox Host (script)

> This script will create an **unprivileged** LXC with `nesting=1` and `keyctl=1` enabled, configure network, install base tools, and allow **root SSH login** (⚠️ security risk if exposed to the internet — use only in secure networks).

**Script: `create-arr-lxc.sh`**
```bash
#!/usr/bin/env bash
set -euo pipefail

# ===== User settings =====
CTID=103
HOSTNAME="arr-ecossystem"
BRIDGE="vmbr0"
IP="192.168.100.41/24"
GW="192.168.100.1"
MEMORY=4096        # MiB
SWAP=1024          # MiB
CORES=4
DISK_SIZE="32G"    # local-lvm
ONBOOT=0           # 1 = start on boot
SSH_PUBKEY="${HOME}/.ssh/id_rsa.pub"   # path to your public key
# =========================

echo "[1/6] Updating Proxmox template list..."
pveam update
TEMPLATE=$(pveam available | awk '/alpine-3\.22-default.*amd64.*tar\.xz/{print $2}' | tail -n1)
if [[ -z "$TEMPLATE" ]]; then
  echo "Alpine 3.22 template not found."; exit 1
fi
pveam download local "$TEMPLATE"

echo "[2/6] Creating LXC $CTID ($HOSTNAME)..."
pct create "$CTID" "local:vztmpl/${TEMPLATE##*/}" \
  -hostname "$HOSTNAME" \
  -ostype alpine \
  -arch amd64 \
  -unprivileged 1 \
  -features nesting=1,keyctl=1 \
  -memory "$MEMORY" \
  -swap "$SWAP" \
  -cores "$CORES" \
  -rootfs "local-lvm:$DISK_SIZE" \
  -net0 "name=eth0,bridge=$BRIDGE,ip=$IP,gw=$GW,firewall=1" \
  -onboot "$ONBOOT"

if [[ -f "$SSH_PUBKEY" ]]; then
  echo "[3/6] Injecting SSH public key..."
  pct set "$CTID" -ssh-public-keys "$SSH_PUBKEY"
fi

echo "[4/6] Starting container..."
pct start "$CTID"
sleep 5

echo "[5/6] Installing base packages inside container..."
pct exec "$CTID" -- sh -c "
  apk update &&
  apk add --no-cache nano net-tools openssh &&
  rc-update add sshd default &&
  sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config &&
  service sshd start
"

echo "[6/6] Container ready."
echo "⚠️ Root SSH login is enabled — disable or secure it if container is internet-facing."
echo "Access via: ssh root@${IP%/*}"
```

**Run from Proxmox host:**
```bash
chmod +x create-arr-lxc.sh
./create-arr-lxc.sh
```

---

## 1) Base Environment inside Alpine LXC

Inside the container:
```sh
apk update
apk add --no-cache docker docker-cli-compose curl ca-certificates tzdata nano
rc-update add docker default
service docker start
```

---

## 2) Folder Structure (script inside container)

Create `criar_estrutura.sh`:
```sh
#!/bin/sh

for d in sonarr radarr readarr prowlarr bazarr; do
  mkdir -p "/srv/arr/$d"
done

mkdir -p /srv/data/media /srv/data/downloads
chown -R arr:docker /srv/arr /srv/data
```
Run:
```sh
chmod +x criar_estrutura.sh
./criar_estrutura.sh
```

---

## 3) Get UID/GID for Docker volumes
```sh
docker run --rm hello-world
id arr
```
Example:
```
uid=101(arr) gid=102(docker) groups=102(docker),102(docker)
```

---

## 4) Docker Compose for ARR Services
Create `/srv/arr/docker-compose.yml`:
```yaml
services:
  prowlarr:
    image: lscr.io/linuxserver/prowlarr:latest
    container_name: prowlarr
    environment:
      - PUID=101
      - PGID=102
      - TZ=Europe/Lisbon
    volumes:
      - /srv/arr/prowlarr:/config
    ports:
      - "9696:9696"
    restart: unless-stopped

  sonarr:
    image: lscr.io/linuxserver/sonarr:latest
    container_name: sonarr
    environment:
      - PUID=101
      - PGID=102
      - TZ=Europe/Lisbon
    volumes:
      - /srv/arr/sonarr:/config
      - /srv/data/media:/media
      - /srv/data/downloads:/downloads
    ports:
      - "8989:8989"
    depends_on: [prowlarr]
    restart: unless-stopped

  radarr:
    image: lscr.io/linuxserver/radarr:latest
    container_name: radarr
    environment:
      - PUID=101
      - PGID=102
      - TZ=Europe/Lisbon
    volumes:
      - /srv/arr/radarr:/config
      - /srv/data/media:/media
      - /srv/data/downloads:/downloads
    ports:
      - "7878:7878"
    depends_on: [prowlarr]
    restart: unless-stopped

  bazarr:
    image: lscr.io/linuxserver/bazarr:latest
    container_name: bazarr
    environment:
      - PUID=101
      - PGID=102
      - TZ=Europe/Lisbon
    volumes:
      - /srv/arr/bazarr:/config
      - /srv/data/media:/media
      - /srv/data/downloads:/downloads
    ports:
      - "6767:6767"
    depends_on: [sonarr, radarr]
    restart: unless-stopped
```
Run:
```sh
cd /srv/arr
docker compose pull
docker compose up -d
```

---

## 5) Let's Encrypt Certificates on Reverse Proxy

Stop Nginx:
```sh
rc-service nginx stop
```
Ensure DNS A records point to your proxy's public IP:
```sh
certbot certonly --standalone -d sonarr.domain.com
certbot certonly --standalone -d radarr.domain.com
certbot certonly --standalone -d prowlarr.domain.com
certbot certonly --standalone -d bazarr.domain.com
```
Start Nginx:
```sh
rc-service nginx start
```

---

## 6) Nginx Reverse Proxy Config

Example for `sonarr.domain.com`:
```nginx
server {
    listen 443 ssl;
    server_name sonarr.domain.com;

    ssl_certificate     /etc/letsencrypt/live/sonarr.domain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/sonarr.domain.com/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    location / {
        proxy_pass http://192.168.100.41:8989;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
server {
    listen 80;
    server_name sonarr.domain.com;
    return 301 https://$host$request_uri;
}
```
Repeat for:
- `radarr.domain.com` → port 7878
- `prowlarr.domain.com` → port 9696
- `bazarr.domain.com` → port 6767

---

## 7) Post-install Checklist

- Access each app via HTTPS subdomain
- Add & sync Sonarr/Radarr in Prowlarr
- Ensure `/media` and `/downloads` paths match in apps
- Fix perms if needed:
```sh
chown -R arr:docker /srv/arr /srv/data
```
- Backup configs:
```sh
tar czf arr-configs-$(date +%F).tgz /srv/arr
```
