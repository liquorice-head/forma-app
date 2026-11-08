#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
configuration="${1:-debug}"
signingIdentity="${FORMA_SIGN_IDENTITY:-}"
cloudProfile="${FORMA_CLOUD_PROFILE:-}"
if [[ -z "$cloudProfile" && -f .release-config-cloud-profile ]]; then
    cloudProfile="$(<.release-config-cloud-profile)"
fi
if [[ -z "$signingIdentity" && -f .forma-signing-identity ]]; then
    signingIdentity="$(<.forma-signing-identity)"
fi
if [[ -z "$signingIdentity" ]]; then
    if [[ "${FORMA_ALLOW_ADHOC:-0}" == 1 ]]; then
        signingIdentity="-"
    else
        print -u2 'Set FORMA_SIGN_IDENTITY or save a signing certificate fingerprint in .forma-signing-identity.'
        print -u2 'A stable Apple signing identity is required to preserve Keychain and Accessibility approvals between builds.'
        exit 1
    fi
fi
if [[ "$signingIdentity" == "-" && "${FORMA_ALLOW_ADHOC:-0}" != 1 ]]; then
    print -u2 'Ad-hoc signing must be explicitly enabled with FORMA_ALLOW_ADHOC=1.'
    exit 1
fi
taskCache="${TMPDIR:-/tmp}/forma-build"
mkdir -p "$taskCache"
export CLANG_MODULE_CACHE_PATH="$taskCache/clang"
export SWIFT_MODULECACHE_PATH="$taskCache/swift"
export MACOSX_DEPLOYMENT_TARGET=26.0
buildOptions=(--disable-sandbox --configuration "$configuration" -debug-info-format none --cache-path "$taskCache/packages" --config-path "$taskCache/config" --security-path "$taskCache/security" -Xswiftc -module-cache-path -Xswiftc "$taskCache/swift")
buildOptions+=(--arch arm64)
swift build "${buildOptions[@]}"
binPath="$(swift build "${buildOptions[@]}" --show-bin-path)"
stageDirectory="$(mktemp -d "$taskCache/bundle.XXXXXX")"
stageApp="$stageDirectory/Forma.app"
cleanup() {
    if [[ -d "$stageDirectory/previous.app" && ! -d dist/Forma.app ]]; then
        mv "$stageDirectory/previous.app" dist/Forma.app
    fi
    rm -rf "$stageDirectory"
}
trap cleanup EXIT
mkdir -p "$stageApp/Contents/MacOS" "$stageApp/Contents/Resources"
cp "$binPath/Forma" "$stageApp/Contents/MacOS/Forma"
frameworkSource=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
framework="$stageApp/Contents/Frameworks/Sparkle.framework"
mkdir -p "$stageApp/Contents/Frameworks"
ditto "$frameworkSource" "$framework"
cp .build/artifacts/sparkle/Sparkle/LICENSE "$stageApp/Contents/Resources/Sparkle-LICENSE.txt"
signOptions=(--force --options runtime --preserve-metadata=entitlements --sign "$signingIdentity")
if [[ "${FORMA_DISTRIBUTION:-0}" == 1 ]]; then
    signOptions+=(--timestamp)
else
    signOptions+=(--timestamp=none)
fi
for component in "$framework/Versions/B/XPCServices/Installer.xpc" "$framework/Versions/B/XPCServices/Downloader.xpc" "$framework/Versions/B/Autoupdate" "$framework/Versions/B/Updater.app"; do
    if [[ -e "$component" ]]; then codesign "${signOptions[@]}" "$component"; fi
done
codesign "${signOptions[@]}" "$framework"
xcrun actool --compile "$stageApp/Contents/Resources" --platform macosx \
    --minimum-deployment-target 26.0 --app-icon AppIcon \
    --output-partial-info-plist "$taskCache/icon-info.plist" Sources/Forma/Resources/AppIcon.icon
cp scripts/Info.plist "$stageApp/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "${FORMA_BUNDLE_ID:-app.forma.prototype}" "$stageApp/Contents/Info.plist"
appSignOptions=("${signOptions[@]}")
if [[ -n "$cloudProfile" ]]; then
    bundleID="${FORMA_BUNDLE_ID:-app.forma.prototype}"
    containerID="${FORMA_CLOUD_CONTAINER:-iCloud.$bundleID}"
    python3 scripts/configure-cloud-signing.py --profile "$cloudProfile" \
        --bundle-id "$bundleID" --identity "$signingIdentity" \
        --container-id "$containerID" --output "$stageDirectory/cloud.entitlements"
    cp "$cloudProfile" "$stageApp/Contents/embedded.provisionprofile"
    plutil -replace FormaCloudContainerIdentifier -string "$containerID" "$stageApp/Contents/Info.plist"
    appSignOptions+=(--entitlements "$stageDirectory/cloud.entitlements")
else
    plutil -remove FormaCloudContainerIdentifier "$stageApp/Contents/Info.plist"
fi
codesign "${appSignOptions[@]}" "$stageApp"
codesign --verify --deep --strict "$stageApp"
mkdir -p dist
if [[ -d dist/Forma.app ]]; then mv dist/Forma.app "$stageDirectory/previous.app"; fi
mv "$stageApp" dist/Forma.app
echo "Built: ${PWD}/dist/Forma.app"
