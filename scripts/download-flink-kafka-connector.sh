#!/usr/bin/env bash
set -euo pipefail

# Download the Flink SQL Kafka connector jar into flink/usrlib.
# This jar is required by SQL Client jobs that read/write Kafka tables.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET_DIR="$REPO_ROOT/flink/usrlib"
JAR_NAME="${JAR_NAME:-flink-sql-connector-kafka-3.2.0-1.19.jar}"
JAR_URL="${JAR_URL:-https://repo1.maven.org/maven2/org/apache/flink/flink-sql-connector-kafka/3.2.0-1.19/$JAR_NAME}"
TARGET_PATH="$TARGET_DIR/$JAR_NAME"

mkdir -p "$TARGET_DIR"

if [ -f "$TARGET_PATH" ]; then
  echo "[INFO] Connector already exists: $TARGET_PATH"
  exit 0
fi

if command -v curl >/dev/null 2>&1; then
  echo "[INFO] Downloading with curl: $JAR_URL"
  curl -fL "$JAR_URL" -o "$TARGET_PATH"
elif command -v wget >/dev/null 2>&1; then
  echo "[INFO] Downloading with wget: $JAR_URL"
  wget -O "$TARGET_PATH" "$JAR_URL"
else
  echo "[ERROR] Neither curl nor wget is installed."
  exit 1
fi

echo "[INFO] Saved: $TARGET_PATH"
