#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_IMAGE="${1:-$ROOT/Resources/Branding/AppIconSource.jpg}"
MASTER_IMAGE="$ROOT/Resources/Branding/AppIconMaster.png"
SCALE="${NOMVA_ICON_SCALE:-1.52}"
MODULE_CACHE="$ROOT/.swift-module-cache"

mkdir -p "$MODULE_CACHE"

SWIFT_MODULECACHE_PATH="$MODULE_CACHE" \
CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
swift - "$SOURCE_IMAGE" "$MASTER_IMAGE" "$SCALE" <<'SWIFT'
import AppKit

let sourcePath = CommandLine.arguments[1]
let masterPath = CommandLine.arguments[2]
let scale = CGFloat(Double(CommandLine.arguments[3]) ?? 1.52)
let canvasSize = CGSize(width: 1024, height: 1024)
let scaled = CGSize(width: canvasSize.width * scale, height: canvasSize.height * scale)
let drawRect = CGRect(
    x: (canvasSize.width - scaled.width) / 2.0,
    y: (canvasSize.height - scaled.height) / 2.0,
    width: scaled.width,
    height: scaled.height
)

guard let source = NSImage(contentsOfFile: sourcePath) else {
    fatalError("Could not load icon source at \(sourcePath)")
}

let image = NSImage(size: canvasSize)
image.lockFocus()
NSGraphicsContext.current?.imageInterpolation = .high
NSColor.white.setFill()
NSBezierPath(rect: CGRect(origin: .zero, size: canvasSize)).fill()
source.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let data = rep.representation(using: .png, properties: [:]) else {
    fatalError("Could not render icon master")
}

try data.write(to: URL(fileURLWithPath: masterPath))
print(masterPath)
SWIFT

cp "$MASTER_IMAGE" "$ROOT/appstore.png"
sips -z 512 512 "$MASTER_IMAGE" --out "$ROOT/server/public/logo.png" >/dev/null

cp "$MASTER_IMAGE" "$ROOT/Nomva/Assets.xcassets/AppIcon.appiconset/AppIcon-Any-1024.png"

cat >"$ROOT/Nomva/Assets.xcassets/AppIcon.appiconset/Contents.json" <<'JSON'
{
  "images" : [
    {
      "filename" : "AppIcon-Any-1024.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    },
    {
      "filename" : "AppIcon-Any-1024.png",
      "idiom" : "ios-marketing",
      "scale" : "1x",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON

find "$ROOT/Nomva/Assets.xcassets" -path '*/[0-9]*.imageset/[0-9]*.png' -print0 | while IFS= read -r -d '' file; do
  size="$(basename "$file" | sed -E 's/([0-9]+)\.png/\1/')"
  sips -z "$size" "$size" "$MASTER_IMAGE" --out "$file" >/dev/null
done

echo "Regenerated Nomva app icons from $SOURCE_IMAGE at scale $SCALE"
