#!/bin/sh
set -e

# Konfiguration
DOCKERHUB_USER="${DOCKERHUB_USER:-beroliv}"
REPO_NAME="typenschein"
BASE_IMAGE="$DOCKERHUB_USER/$REPO_NAME"
TAG="${1:-latest}"             # z.B. v1.0.0 oder "latest"
IMAGE="$BASE_IMAGE:$TAG"
CONTAINER_NAME="typenschein"
VOLUME_NAME="typenschein-data"
PORT="${2:-5050}"

echo "==> Installiere Typenschein-App: $IMAGE"
echo "Port: $PORT, Volume: $VOLUME_NAME, Container: $CONTAINER_NAME"

# Prüfen ob docker vorhanden ist
if ! command -v docker >/dev/null 2>&1; then
  echo "Fehler: 'docker' ist nicht installiert."
  exit 1
fi

# Volume sicherstellen
echo "==> Stelle sicher, dass Volume '$VOLUME_NAME' existiert"
if docker volume ls --format '{{.Name}}' | grep -qx "$VOLUME_NAME"; then
  echo "Volume existiert: $VOLUME_NAME"
else
  docker volume create "$VOLUME_NAME"
  echo "Volume erstellt: $VOLUME_NAME"
fi

# Image bauen
echo "==> Baue Docker-Image: $IMAGE"
docker build -t "$IMAGE" .

# Alten Container entfernen
if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  echo "==> Entferne bestehenden Container '$CONTAINER_NAME'"
  docker rm -f "$CONTAINER_NAME"
fi

# Container starten mit Volume
echo "==> Starte Container '$CONTAINER_NAME' auf Port $PORT mit Volume '$VOLUME_NAME'"
docker run -d \
  --name "$CONTAINER_NAME" \
  -p "${PORT}":5000 \
  -v "${VOLUME_NAME}":/app/data:rw \
  --restart unless-stopped \
  "$IMAGE"

echo ""
echo "==> Fertig. Webinterface erreichbar unter: http://<host>:${PORT}"
echo "Datenupdate manuell: http://<host>:${PORT}/update"
