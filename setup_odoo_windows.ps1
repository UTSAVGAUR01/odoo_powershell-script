# PowerShell script to set up Odoo and PostgreSQL on Windows 10 with Docker Desktop
# Tailored for H:\docker_odoo, with custom jkmall:18.0 image, PostgreSQL 15, module installation

$RepoUrl = "https://github.com/Utsavgaur/odoo_jkmall.git"
$RepoBranch = "odoo_jkmall_v1"
$WorkDir = "H:\docker_odoo"
$NetworkName = "maeko-network"
$OdooContainer = "maeko_payroll"
$PostgresContainer = "maeko_postgres"
$PostgresDb = "maeko_payroll25_db"
$PostgresUser = "maeko_user"
$PostgresPassword = "maeko_p@zzword_125"
$PostgresPort = 5432
$ImageName = "jkmall:18.0"

# Function to log messages
function Log-Message {
    param ([string]$Message)
    Write-Host "[$(Get-Date)] $Message"
}

# 1. Check prerequisites
Log-Message "Checking prerequisites..."
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Log-Message "Error: Docker not installed. Install Docker Desktop."
    exit 1
}
try {
    docker info | Out-Null
} catch {
    Log-Message "Error: Docker Desktop not running."
    exit 1
}
if (-not (Get-Command docker-compose -ErrorAction SilentlyContinue)) {
    Log-Message "Error: docker-compose not installed. See https://docs.docker.com/compose/install/"
    exit 1
}
if (-not (Test-Connection 8.8.8.8 -Count 1 -Quiet)) {
    Log-Message "Warning: No internet connection. Cloning may fail."
}
$freeSpace = (Get-PSDrive H | Select-Object -ExpandProperty Free) / 1MB
if ($freeSpace -lt 10000) {
    Log-Message "Error: Need 10GB disk space. Available: $freeSpace MB"
    exit 1
}
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Log-Message "Error: Git not installed. Install Git for Windows."
    exit 1
}
Log-Message "Prerequisites met."

# 2. Create working directory
Log-Message "Creating working directory: $WorkDir"
if (-not (Test-Path $WorkDir)) {
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
    if (-not (Test-Path $WorkDir)) {
        Log-Message "Error: Failed to create directory $WorkDir. Check permissions on H: drive."
        exit 1
    }
}
Set-Location $WorkDir
Log-Message "Changed to directory: $WorkDir"

# 3. Verify file sharing
Log-Message "Checking Docker Desktop file sharing for $WorkDir..."
try {
    $testOutput = docker run --rm -v "$($WorkDir):/test" alpine ls /test 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Mount failed"
    }
} catch {
    Log-Message "Error: Directory $WorkDir is not shared in Docker Desktop."
    Log-Message "Fix: Open Docker Desktop > Settings > Resources > File Sharing."
    Log-Message "Add $WorkDir and click Apply & Restart."
    exit 1
}
Log-Message "File sharing verified."

# 4. Configure Git settings
Log-Message "Configuring Git settings..."
try {
    git config --global http.postBuffer 524288000
    git config --global http.lowSpeedLimit 0
    git config --global http.lowSpeedTime 999999
} catch {
    Log-Message "Warning: Failed to configure Git settings. Proceeding..."
}

# 5. Clone repository
Log-Message "Cloning repository..."
$repoPath = Join-Path $WorkDir "odoo"
if (Test-Path "$repoPath\.git") {
    Log-Message "Repository already exists."
} else {
    try {
        git clone --branch $RepoBranch --depth 1 $RepoUrl odoo 2>&1 | Out-String | Write-Host
        if (-not (Test-Path "$repoPath\.git")) {
            throw "Clone failed"
        }
    } catch {
        Log-Message "Warning: Failed to clone repository ($RepoUrl, branch $RepoBranch)."
        New-Item -ItemType Directory -Path $repoPath -Force | Out-Null
    }
}
Log-Message "Checking repository contents..."
$repoContents = Get-ChildItem -Path $repoPath -ErrorAction SilentlyContinue
if ($repoContents) {
    $repoContents | ForEach-Object { Log-Message "Found: $($_.Name)" }
} else {
    Log-Message "Warning: Repository directory is empty or inaccessible."
}
Log-Message "Repository setup complete."

# 6. Check for existing PostgreSQL volume
Log-Message "Checking for existing PostgreSQL volume..."
$volumeExists = docker volume ls -q | Where-Object { $_ -eq "docker_odoo_postgres_data" }
if ($volumeExists) {
    Log-Message "Warning: Existing 'docker_odoo_postgres_data' volume detected. Upgrading to PostgreSQL 15 may require data migration."
    Log-Message "To start fresh, remove the volume with: docker volume rm docker_odoo_postgres_data"
}

# 7. Create Dockerfile
Log-Message "Creating Dockerfile..."
$dockerfileContent = @"
FROM odoo:18
COPY odoo/addons /mnt/extra-addons
COPY odoo.conf /etc/odoo/odoo.conf
EXPOSE 8069
CMD ["odoo", "--config=/etc/odoo/odoo.conf"]
"@
$dockerfilePath = Join-Path $WorkDir "Dockerfile"
[System.IO.File]::WriteAllText($dockerfilePath, $dockerfileContent, [System.Text.UTF8Encoding]::new($false))
Log-Message "Dockerfile created at $dockerfilePath"
Log-Message "Dockerfile content:"
Get-Content $dockerfilePath | ForEach-Object { Log-Message $_ }

# 8. Create odoo.conf
Log-Message "Creating odoo.conf..."
$odooConfContent = @"
[options]
admin_passwd = $PostgresPassword
db_host = $PostgresContainer
db_port = $PostgresPort
db_user = $PostgresUser
db_password = $PostgresPassword
db_name = $PostgresDb
without_demo = all
addons_path = /mnt/extra-addons,/usr/lib/python3/dist-packages/odoo/addons
"@
$odooConfPath = Join-Path $WorkDir "odoo.conf"
[System.IO.File]::WriteAllText($odooConfPath, $odooConfContent, [System.Text.UTF8Encoding]::new($false))
Log-Message "odoo.conf created at $odooConfPath"
Log-Message "odoo.conf content:"
Get-Content $odooConfPath | ForEach-Object { Log-Message $_ }

# 9. Create docker-compose.yaml
Log-Message "Creating docker-compose.yaml..."
$odooVolumePath = (Join-Path $repoPath "addons") -replace '\\', '/' # e.g., H:/docker_odoo/odoo/addons
$dockerComposeContent = @"
services:
  odoo:
    image: $ImageName
    container_name: $OdooContainer
    build:
      context: .
      dockerfile: Dockerfile
    ports:
      - 8076:8069
    environment:
      - HOST=$PostgresContainer
      - USER=$PostgresUser
      - PASSWORD=$PostgresPassword
    volumes:
      - ${odooVolumePath}:/mnt/extra-addons
      - odoo_data:/var/lib/odoo
    depends_on:
      - postgres
    networks:
      - odoo-net
  postgres:
    image: postgres:15
    container_name: $PostgresContainer
    environment:
      - POSTGRES_DB=$PostgresDb
      - POSTGRES_USER=$PostgresUser
      - POSTGRES_PASSWORD=$PostgresPassword
    ports:
      - ${PostgresPort}:5432
    volumes:
      - postgres_data:/var/lib/postgresql/data
    networks:
      - odoo-net
volumes:
  odoo_data:
  postgres_data:
networks:
  odoo-net:
    name: $NetworkName
"@
$dockerComposePath = Join-Path $WorkDir "docker-compose.yaml"
[System.IO.File]::WriteAllText($dockerComposePath, $dockerComposeContent, [System.Text.UTF8Encoding]::new($false))
Log-Message "docker-compose.yaml created at $dockerComposePath"
Log-Message "docker-compose.yaml content:"
Get-Content $dockerComposePath | ForEach-Object { Log-Message $_ }

# 10. Validate docker-compose.yaml
Log-Message "Validating docker-compose.yaml..."
try {
    docker-compose config 2>&1 | Out-String | Write-Host
    if ($LASTEXITCODE -ne 0) {
        throw "Invalid docker-compose.yaml"
    }
} catch {
    Log-Message "Error: Invalid docker-compose.yaml. Check syntax."
    exit 1
}
Log-Message "docker-compose.yaml validated."

# 11. Clean up existing containers
Log-Message "Cleaning up existing containers..."
try {
    docker-compose down 2>&1 | Out-String | Write-Host
} catch {
    Log-Message "Warning: docker-compose down failed, proceeding..."
}
docker rm -f $OdooContainer 2>&1 | Out-Null
docker rm -f $PostgresContainer 2>&1 | Out-Null
Log-Message "Cleanup complete."

# 12. Build custom image
Log-Message "Building custom image $ImageName..."
try {
    docker-compose build odoo 2>&1 | Out-String | Write-Host
    if ($LASTEXITCODE -ne 0) {
        throw "Build failed"
    }
} catch {
    Log-Message "Error: Failed to build $ImageName. Check Docker logs."
    docker images | Out-String | Write-Host
    exit 1
}
Log-Message "Image $ImageName built."

# 13. Start services
Log-Message "Starting services..."
try {
    docker-compose up -d 2>&1 | Out-String | Write-Host
} catch {
    Log-Message "Error: Failed to start services. Checking docker-compose logs..."
    docker-compose logs 2>&1 | Out-String | Write-Host
    exit 1
}
Log-Message "Services started."

# 14. Initialize Odoo modules
Log-Message "Initializing Odoo modules with 'odoo -u all --without-demo=all --stop-after-init'..."
try {
    docker exec $OdooContainer odoo -u all --without-demo=all --stop-after-init 2>&1 | Out-String | Write-Host
    if ($LASTEXITCODE -ne 0) {
        throw "Module initialization failed"
    }
    Log-Message "Module initialization complete. Restarting Odoo container..."
    docker restart $OdooContainer 2>&1 | Out-String | Write-Host
} catch {
    Log-Message "Error: Failed to initialize modules. Checking Odoo logs..."
    docker logs $OdooContainer 2>&1 | Out-String | Write-Host
    exit 1
}

# 15. Verify containers
Log-Message "Verifying containers..."
Start-Sleep -Seconds 5
$odooRunning = docker ps -q -f "name=$OdooContainer"
$postgresRunning = docker ps -q -f "name=$PostgresContainer"
if (-not $odooRunning) {
    Log-Message "Error: Odoo container not running. Attempting restart..."
    try {
        docker restart $OdooContainer 2>&1 | Out-String | Write-Host
        Start-Sleep -Seconds 5
        $odooRunning = docker ps -q -f "name=$OdooContainer"
    } catch {
        Log-Message "Error: Failed to restart Odoo container."
    }
    if (-not $odooRunning) {
        Log-Message "Checking Odoo logs..."
        try {
            docker logs $OdooContainer 2>&1 | Out-String | Write-Host
        } catch {
            Log-Message "Error: No logs available for $OdooContainer."
        }
    }
}
if (-not $postgresRunning) {
    Log-Message "Error: PostgreSQL container not running. Attempting restart..."
    try {
        docker restart $PostgresContainer 2>&1 | Out-String | Write-Host
        Start-Sleep -Seconds 5
        $postgresRunning = docker ps -q -f "name=$PostgresContainer"
    } catch {
        Log-Message "Error: Failed to restart PostgreSQL container."
    }
    if (-not $postgresRunning) {
        Log-Message "Checking PostgreSQL logs..."
        try {
            docker logs $PostgresContainer 2>&1 | Out-String | Write-Host
        } catch {
            Log-Message "Error: No logs available for $PostgresContainer."
        }
    }
}
if (-not $odooRunning -or -not $postgresRunning) {
    Log-Message "Error: One or more containers failed to start."
    exit 1
}
Log-Message "Containers are running."

# 16. Verify Odoo configuration
Log-Message "Verifying Odoo configuration..."
try {
    docker exec $OdooContainer cat /etc/odoo/odoo.conf 2>&1 | Out-String | Write-Host
} catch {
    Log-Message "Error: Failed to read Odoo configuration. Checking container logs..."
    docker logs $OdooContainer 2>&1 | Out-String | Write-Host
    exit 1
}
Log-Message "Odoo configuration verified."

# 17. Verify Odoo addons
Log-Message "Verifying Odoo addons..."
Start-Sleep -Seconds 10
try {
    docker exec $OdooContainer ls /mnt/extra-addons 2>&1 | Out-String | Write-Host
} catch {
    Log-Message "Error: Failed to access addons directory. Checking Odoo logs..."
    docker logs $OdooContainer 2>&1 | Out-String | Write-Host
    exit 1
}
Log-Message "Odoo setup complete."
Log-Message "Odoo running at http://localhost:8076"
Log-Message "PostgreSQL running at localhost:$PostgresPort"
Log-Message "To debug issues, run:"
Log-Message "  docker logs $OdooContainer"
Log-Message "  docker logs $PostgresContainer"
Log-Message "Ensure $WorkDir is shared in Docker Desktop Settings > Resources > File Sharing."
##odoo -u all --without-demo=all --stop-after-init
