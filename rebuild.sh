#!/bin/bash
set -euo pipefail

# Radarr Custom Build & Deploy Script
# Rebuilds the custom Radarr image from the fork and redeploys the container.
#
# Usage:
#   ./rebuild.sh              # Rebuild locally from current branch
#   ./rebuild.sh --update     # Pull latest from upstream, rebase, then rebuild
#   ./rebuild.sh --rebase     # Same as --update
#   ./rebuild.sh --pull       # Pull pre-built image from GHCR (built by GitHub Actions)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FORK_DIR="$SCRIPT_DIR"
PUBLISH_DIR="$FORK_DIR/_publish"
PUBLISH_MONO_DIR="$FORK_DIR/_publish_mono"
IMAGE_NAME="radarr-custom:latest"
CONTAINER_NAME="radarr"
DOTNET_PATH="/usr/local/dotnet"
TAILSCALE_IP="100.126.210.88"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1"; exit 1; }

cd "$FORK_DIR"

GHCR_IMAGE="ghcr.io/exwithbenefits/radarr-custom:latest"

# Option: pull pre-built image from GHCR
if [[ "${1:-}" == "--pull" ]]; then
    log "Pulling pre-built image from GHCR..."
    docker pull "$GHCR_IMAGE" || err "Failed to pull from GHCR. Check GitHub Actions build status."
    docker tag "$GHCR_IMAGE" "$IMAGE_NAME"
    log "Tagged as $IMAGE_NAME"

    log "Stopping old container..."
    docker stop "$CONTAINER_NAME" 2>/dev/null || true
    docker rm "$CONTAINER_NAME" 2>/dev/null || true

    log "Starting new container..."
    docker run -d \
        --name "$CONTAINER_NAME" \
        --restart unless-stopped \
        --network sushiworks \
        -p "${TAILSCALE_IP}:17878:7878" \
        -v /sbx/appdata/radarr:/config \
        -v /sbx/data:/sbx/data \
        -v /sbx/mnt:/sbx/mnt \
        -e PUID=0 -e PGID=0 -e UMASK=002 \
        -e DOTNET_GCServer=1 -e DOTNET_ThreadPool_MinThreads=200 \
        -e DOTNET_TieredPGO=1 -e DOTNET_THREADPOOL_MINTHREADS=200 \
        -e DOTNET_GCConcurrent=1 \
        "$IMAGE_NAME" || err "Container start failed"

    log "Done! Deployed from GHCR."
    exit 0
fi

# Optional: pull upstream and rebase
if [[ "${1:-}" == "--update" || "${1:-}" == "--rebase" ]]; then
    log "Fetching upstream..."
    git fetch upstream

    BRANCH=$(git branch --show-current)
    log "Rebasing $BRANCH onto upstream/develop..."
    if ! git rebase upstream/develop; then
        err "Rebase failed! Resolve conflicts, then run: git rebase --continue && ./rebuild.sh"
    fi

    log "Pushing rebased branch to origin..."
    git push origin "$BRANCH" --force-with-lease
fi

# Step 1: Publish main app
log "Publishing Radarr (self-contained, linux-musl-x64)..."
rm -rf "$PUBLISH_DIR"
export PATH="$DOTNET_PATH:$PATH"
dotnet publish "$FORK_DIR/src/NzbDrone.Console/Radarr.Console.csproj" \
    -c Release -f net8.0 -r linux-musl-x64 --self-contained true \
    -o "$PUBLISH_DIR" \
    /p:AnalysisLevel=none /p:EnforceCodeStyleInBuild=false /p:RunAnalyzers=false \
    || err "dotnet publish failed"

# Step 2: Publish Radarr.Mono (dynamically loaded on Linux)
log "Publishing Radarr.Mono..."
rm -rf "$PUBLISH_MONO_DIR"
dotnet publish "$FORK_DIR/src/NzbDrone.Mono/Radarr.Mono.csproj" \
    -c Release -f net8.0 -r linux-musl-x64 --self-contained false \
    -o "$PUBLISH_MONO_DIR" \
    /p:AnalysisLevel=none /p:EnforceCodeStyleInBuild=false /p:RunAnalyzers=false \
    || err "Radarr.Mono publish failed"

# Step 3: Copy Mono deps into main publish
log "Copying Mono dependencies..."
cp "$PUBLISH_MONO_DIR/Radarr.Mono.dll" "$PUBLISH_DIR/"
cp "$PUBLISH_MONO_DIR/Radarr.Mono.pdb" "$PUBLISH_DIR/" 2>/dev/null || true
cp "$PUBLISH_MONO_DIR/Mono.Posix.NETStandard.dll" "$PUBLISH_DIR/"
cp "$PUBLISH_MONO_DIR/libMonoPosixHelper.so" "$PUBLISH_DIR/"

# Step 4: Build Docker image
log "Building Docker image: $IMAGE_NAME..."
docker build -t "$IMAGE_NAME" "$FORK_DIR/" || err "Docker build failed"

# Step 5: Deploy
log "Stopping old container..."
docker stop "$CONTAINER_NAME" 2>/dev/null || true
docker rm "$CONTAINER_NAME" 2>/dev/null || true

log "Starting new container..."
docker run -d \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    --network sushiworks \
    -p "${TAILSCALE_IP}:17878:7878" \
    -v /sbx/appdata/radarr:/config \
    -v /sbx/data:/sbx/data \
    -v /sbx/mnt:/sbx/mnt \
    -e PUID=0 \
    -e PGID=0 \
    -e UMASK=002 \
    -e DOTNET_GCServer=1 \
    -e DOTNET_ThreadPool_MinThreads=200 \
    -e DOTNET_TieredPGO=1 \
    -e DOTNET_THREADPOOL_MINTHREADS=200 \
    -e DOTNET_GCConcurrent=1 \
    "$IMAGE_NAME" || err "Container start failed"

# Step 6: Verify
log "Waiting for Radarr to start..."
sleep 15

API_KEY=$(grep -oP '(?<=<ApiKey>).*(?=</ApiKey>)' /sbx/appdata/radarr/config.xml 2>/dev/null || echo "")
if [[ -n "$API_KEY" ]]; then
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        "http://${TAILSCALE_IP}:17878/api/v3/system/status" \
        -H "X-Api-Key: $API_KEY" --max-time 10 2>/dev/null || echo "000")

    if [[ "$HTTP_CODE" == "200" ]]; then
        VERSION=$(curl -s "http://${TAILSCALE_IP}:17878/api/v3/system/status" \
            -H "X-Api-Key: $API_KEY" --max-time 10 2>/dev/null | \
            python3 -c "import sys,json; print(json.load(sys.stdin).get('version','unknown'))" 2>/dev/null || echo "unknown")
        log "Radarr is running! Version: $VERSION"
    else
        warn "Radarr returned HTTP $HTTP_CODE - check logs: docker logs $CONTAINER_NAME"
    fi
else
    warn "Could not find API key - check manually: http://${TAILSCALE_IP}:17878"
fi

log "Done! Image: $IMAGE_NAME"
