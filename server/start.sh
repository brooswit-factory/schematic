#!/usr/bin/env bash
# Sample Forge 1.20.1 server start script for the schematic modpack.
#
# Run once (or whenever the pack changes) to sync mods via packwiz-installer,
# then launch the Forge server. See server/README.md for full setup steps.
set -euo pipefail

cd "$(dirname "$0")"

# Pinned packwiz-installer-bootstrap release — bump deliberately.
# https://github.com/packwiz/packwiz-installer-bootstrap
BOOTSTRAP_VERSION="v0.0.3"
BOOTSTRAP_JAR="packwiz-installer-bootstrap.jar"

if [ ! -f "$BOOTSTRAP_JAR" ]; then
  echo "Downloading packwiz-installer-bootstrap $BOOTSTRAP_VERSION..."
  curl -fsSL -o "$BOOTSTRAP_JAR" \
    "https://github.com/packwiz/packwiz-installer-bootstrap/releases/download/${BOOTSTRAP_VERSION}/packwiz-installer-bootstrap.jar"
fi

# PACK_URL points at the pack.toml uploaded by .github/workflows/server-update.yml
# (see FTP_REMOTE_DIR), or a local path if you sync it some other way.
PACK_URL="${PACK_URL:-./pack.toml}"

# -g accepts the packwiz-installer license non-interactively;
# -s server tells it to install the server-side file set only.
echo "Syncing mods from $PACK_URL..."
java -jar "$BOOTSTRAP_JAR" -g -s server "$PACK_URL"

# Reminder: this only works once you have accepted the Minecraft EULA by
# setting `eula=true` in eula.txt (see server/README.md).
if [ ! -f eula.txt ] || ! grep -q '^eula=true' eula.txt; then
  echo "ERROR: eula.txt is missing or eula=true is not set. See server/README.md." >&2
  exit 1
fi

# Adjust -Xmx/-Xms for your host's available RAM; 4G is a reasonable default
# for a small Create-modpack server.
exec java -Xms1G -Xmx4G -jar server.jar nogui
