#!/bin/bash

# Exit on error
set -e

# Variables
ODOO_VERSION="odoo_jkmall_v1"
IMAGE_NAME="jkmall:18.0"
FALLBACK_IMAGE="odoo:18"
REPO_URL="https://github.com/Utsavgaur/odoo_jkmall.git"
POSTGRES_HOST="maeko_postgres"
POSTGRES_PORT="5432"
POSTGRES_DB="maeko_payroll_git_db"
POSTGRES_USER="maeko_user"
POSTGRES_PASSWORD="maeko_p@zzword_125"
WORKDIR="$(pwd)/odoo_setup"
NETWORK_NAME="maeko-network"
CONTAINER_NAME="maeko_git_odoo"

# 1. Check system requirements
echo "Checking network and disk space..."
ping -c 4 8.8.8.8 >/dev/null 2>&1 || { echo "Error: No internet."; exit 1; }
[ "$(df -m . | tail -1 | awk '{print $4}')" -ge 10000 ] || { echo "Error: Need 10GB disk space."; exit 1; }

# 2. Clone repository
echo "Cloning Odoo custom module repository..."
mkdir -p "$WORKDIR" && cd "$WORKDIR"
if [ -d "odoo/.git" ]; then
    echo "Repository exists."
else
    git clone --branch "$ODOO_VERSION" "$REPO_URL" odoo || { echo "Error: Clone failed."; exit 1; }
fi
mkdir -p addons

# 3. Create configuration files
echo "Creating configuration files..."
cat <<EOF > Dockerfile
FROM odoo:18
COPY odoo/ /mnt/extra-addons/
COPY odoo.conf /etc/odoo/odoo.conf
EXPOSE 8069
CMD ["odoo", "--config=/etc/odoo/odoo.conf"]
EOF

cat <<EOF > odoo.conf
[options]
admin_passwd = maeko_p@zzword_125
db_host = $POSTGRES_HOST
db_port = $POSTGRES_PORT
db_user = $POSTGRES_USER
db_password = $POSTGRES_PASSWORD
db_name = $POSTGRES_DB
without_demo = all
addons_path = /mnt/extra-addons,/opt/odoo/addons
EOF

cat <<EOF > docker-compose.yaml
services:
  odoo:
    image: $IMAGE_NAME
    container_name: $CONTAINER_NAME
    build: .
    ports:
      - "8076:8069"
    environment:
      - HOST=$POSTGRES_HOST
      - USER=$POSTGRES_USER
      - PASSWORD=$POSTGRES_PASSWORD
    volumes:
      - ./addons:/opt/odoo/addons
      - ./odoo:/mnt/extra-addons
      - ./odoo.conf:/etc/odoo/odoo.conf
    networks:
      - odoo-net
networks:
  odoo-net:
    external: true
    name: $NETWORK_NAME
EOF

# 4. Setup network
echo "Setting up Docker network..."
docker network inspect "$NETWORK_NAME" >/dev/null 2>&1 || docker network create "$NETWORK_NAME"
docker ps -q -f name="$POSTGRES_HOST" | grep -q . || { echo "Warning: PostgreSQL container ($POSTGRES_HOST) not running. Ensure it is started."; }

# 5. Clean up existing containers
echo "Stopping and removing existing containers..."
if command -v docker-compose >/dev/null 2>&1; then
    docker-compose down || echo "docker-compose down failed, proceeding..."
elif docker compose version >/dev/null 2>&1; then
    docker compose down || echo "docker compose down failed, proceeding..."
else
    echo "docker-compose not found, removing container manually..."
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || echo "No container to remove."
fi

# 6. Build and start container
echo "Building and starting Odoo..."
if docker build -t "$IMAGE_NAME" .; then
    if command -v docker-compose >/dev/null 2>&1; then
        docker-compose up -d
    elif docker compose version >/dev/null 2>&1; then
        docker compose up -d
    else
        echo "docker-compose not found. Using docker run..."
        docker run -d --name "$CONTAINER_NAME" \
            -p 8076:8069 \
            -v "$WORKDIR/addons:/opt/odoo/addons" \
            -v "$WORKDIR/odoo:/mnt/extra-addons" \
            -v "$WORKDIR/odoo.conf:/etc/odoo/odoo.conf" \
            -e HOST="$POSTGRES_HOST" \
            -e USER="$POSTGRES_USER" \
            -e PASSWORD="$POSTGRES_PASSWORD" \
            --network "$NETWORK_NAME" \
            "$IMAGE_NAME" \
            odoo --config=/etc/odoo/odoo.conf
    fi
else
    echo "Docker build failed. Attempting docker run with fallback image $FALLBACK_IMAGE..."
    docker run -d --name "$CONTAINER_NAME" \
        -p 8076:8069 \
        -v "$WORKDIR/addons:/opt/odoo/addons" \
        -v "$WORKDIR/odoo:/mnt/extra-addons" \
        -v "$WORKDIR/odoo.conf:/etc/odoo/odoo.conf" \
        -e HOST="$POSTGRES_HOST" \
        -e USER="$POSTGRES_USER" \
        -e PASSWORD="$POSTGRES_PASSWORD" \
        --network "$NETWORK_NAME" \
        "$FALLBACK_IMAGE" \
        odoo --config=/etc/odoo/odoo.conf || { echo "Error: Fallback docker run failed."; exit 1; }
fi

# 7. Verify container is running
echo "Verifying container is running..."
docker ps -q -f name="$CONTAINER_NAME" | grep -q . || { echo "Error: Container $CONTAINER_NAME failed to start."; exit 1; }

# 8. Connect container to network
echo "Connecting Odoo container to $NETWORK_NAME..."
docker network connect "$NETWORK_NAME" "$CONTAINER_NAME" || { echo "Error: Failed to connect $CONTAINER_NAME to $NETWORK_NAME."; exit 1; }

# 9. Verify Odoo
echo "Verifying Odoo configuration..."
docker exec "$CONTAINER_NAME" cat /etc/odoo/odoo.conf

echo "Odoo running at http://localhost:8076"
