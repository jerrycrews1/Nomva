#!/bin/sh

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPOSITORY_ROOT="${CI_PRIMARY_REPOSITORY_PATH:-$(dirname "$SCRIPT_DIR")}"
CONFIG_PATH="$SCRIPT_DIR/food-database.env"
DATABASE_PATH="$REPOSITORY_ROOT/Nomva/Resources/foods.sqlite"

if [ ! -f "$CONFIG_PATH" ]; then
    echo "error: Missing food database manifest: $CONFIG_PATH" >&2
    exit 1
fi

# shellcheck disable=SC1090
. "$CONFIG_PATH"

require_value() {
    variable_name="$1"
    eval "variable_value=\${$variable_name:-}"
    if [ -z "$variable_value" ]; then
        echo "error: $variable_name is missing from $CONFIG_PATH" >&2
        exit 1
    fi
}

verify_sha256() {
    file_path="$1"
    expected="$2"
    actual="$(shasum -a 256 "$file_path" | awk '{print $1}')"
    if [ "$actual" != "$expected" ]; then
        echo "error: SHA-256 mismatch for $file_path" >&2
        echo "expected: $expected" >&2
        echo "actual:   $actual" >&2
        exit 1
    fi
}

require_value NOMVA_FOOD_DB_RELEASE
require_value NOMVA_FOOD_DB_ASSET
require_value NOMVA_FOOD_DB_ARCHIVE_SHA256
require_value NOMVA_FOOD_DB_SHA256

if [ -f "$DATABASE_PATH" ]; then
    existing_sha="$(shasum -a 256 "$DATABASE_PATH" | awk '{print $1}')"
    if [ "$existing_sha" = "$NOMVA_FOOD_DB_SHA256" ]; then
        echo "Nomva food database is already present and verified."
        exit 0
    fi
fi

download_url="https://github.com/jerrycrews1/Nomva/releases/download/$NOMVA_FOOD_DB_RELEASE/$NOMVA_FOOD_DB_ASSET"
work_directory="$(mktemp -d "${TMPDIR:-/tmp}/nomva-food-db.XXXXXX")"
archive_path="$work_directory/$NOMVA_FOOD_DB_ASSET"
expanded_path="$work_directory/foods.sqlite"

cleanup() {
    rm -rf "$work_directory"
}
trap cleanup EXIT HUP INT TERM

echo "Downloading Nomva food database from $NOMVA_FOOD_DB_RELEASE..."
curl --fail --location --silent --show-error \
    --retry 5 --retry-delay 2 --connect-timeout 30 \
    --output "$archive_path" "$download_url"

verify_sha256 "$archive_path" "$NOMVA_FOOD_DB_ARCHIVE_SHA256"
gzip -dc "$archive_path" > "$expanded_path"
verify_sha256 "$expanded_path" "$NOMVA_FOOD_DB_SHA256"

integrity_result="$(sqlite3 "$expanded_path" 'PRAGMA quick_check;')"
if [ "$integrity_result" != "ok" ]; then
    echo "error: Downloaded food database failed SQLite integrity validation." >&2
    exit 1
fi

mkdir -p "$(dirname "$DATABASE_PATH")"
mv "$expanded_path" "$DATABASE_PATH"
echo "Nomva food database restored and verified."
