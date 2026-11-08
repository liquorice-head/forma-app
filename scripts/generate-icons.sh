#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
iconWork="$(mktemp -d "${TMPDIR:-/tmp}/forma-icons.XXXXXX")"
trap 'rm -rf "$iconWork"' EXIT
swiftc -module-cache-path "$iconWork/modules" Sources/Forma/BrandIcon.swift scripts/generate-icons.swift -o "$iconWork/generate-icons"
"$iconWork/generate-icons" "$iconWork/output"
mkdir -p Sources/Forma/Resources/AppIcon.icon/Assets previews/brand
cp "$iconWork/output/Forma.png" previews/brand/Forma.png
cp "$iconWork/output/Forma-dark.png" previews/brand/Forma-dark.png
cp "$iconWork/output/Forma-mark.svg" previews/brand/Forma-mark.svg
cp "$iconWork/output/Forma-mark.svg" Sources/Forma/Resources/AppIcon.icon/Assets/Forma-mark.svg
echo "Generated app icon and light/dark previews from BrandIcon.swift"
