#!/usr/bin/env bash
set -euo pipefail

# Experimental iOS XCFramework builder for the Haru-capable speech.cpp release.
# Run on an Apple Silicon Mac with Xcode, CMake, Ninja, and Git installed.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE="${ROOT}/.build"
SOURCE="${CACHE}/speech.cpp-0.11.0"
OUT="${ROOT}/Artifacts"
JOBS="${BUILD_JOBS:-4}"
REVISION="8d18924cd238b87c0297df112f7ff40783a6414f"

mkdir -p "${CACHE}" "${OUT}"

for tool in git cmake ninja xcodebuild xcrun install_name_tool; do
  command -v "${tool}" >/dev/null 2>&1 || {
    echo "Missing required tool: ${tool}" >&2
    exit 1
  }
done

if [[ ! -d "${SOURCE}/.git" ]]; then
  git clone --no-checkout https://github.com/nyosegawa/speech.cpp.git "${SOURCE}"
fi

git -C "${SOURCE}" fetch --depth 1 origin "${REVISION}"
git -C "${SOURCE}" checkout --detach FETCH_HEAD
git -C "${SOURCE}" submodule sync --recursive
git -C "${SOURCE}" submodule update --init --recursive --depth 1

actual_revision="$(git -C "${SOURCE}" rev-parse HEAD)"
if [[ "${actual_revision}" != "${REVISION}" ]]; then
  echo "Unexpected speech.cpp revision: ${actual_revision}" >&2
  exit 1
fi

build_one() {
  local sdk="$1"
  local platform="$2"
  local build="${CACHE}/${sdk}-arm64"
  local framework="${CACHE}/frameworks/${sdk}/SpeechCpp.framework"
  local binary

  cmake -S "${SOURCE}" -B "${build}" -G Ninja \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="${sdk}" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DGGML_NATIVE=OFF \
    -DGGML_OPENMP=OFF \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_METAL_TARGET_OS=ios \
    -DGGML_BLAS=OFF \
    -DGGML_ACCELERATE=ON

  cmake --build "${build}" --target speech --parallel "${JOBS}"

  binary="$(find -L "${build}" -maxdepth 3 -type f -name 'libspeech.4.dylib' -print -quit)"
  if [[ -z "${binary}" ]]; then
    echo "Could not locate libspeech.4.dylib in ${build}" >&2
    find "${build}" -name '*speech*.dylib' -print >&2 || true
    exit 1
  fi

  mkdir -p "${framework}/Headers" "${framework}/Modules"
  cp "${binary}" "${framework}/SpeechCpp"
  cp "${SOURCE}/include/speech.h" "${framework}/Headers/speech.h"
  install_name_tool -id '@rpath/SpeechCpp.framework/SpeechCpp' "${framework}/SpeechCpp"

  cat > "${framework}/Modules/module.modulemap" <<'MODULE'
framework module SpeechCpp {
  umbrella header "speech.h"
  export *
}
MODULE

  cat > "${framework}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.haru4ios.speechcpp</string>
<key>CFBundleName</key><string>SpeechCpp</string>
<key>CFBundleExecutable</key><string>SpeechCpp</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>0.11.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>MinimumOSVersion</key><string>17.0</string>
<key>CFBundleSupportedPlatforms</key><array><string>${platform}</string></array>
</dict></plist>
PLIST
}

build_one iphoneos iPhoneOS
build_one iphonesimulator iPhoneSimulator

STAGE="${CACHE}/SpeechCpp.xcframework"
rm -rf "${STAGE}"
xcodebuild -create-xcframework \
  -framework "${CACHE}/frameworks/iphoneos/SpeechCpp.framework" \
  -framework "${CACHE}/frameworks/iphonesimulator/SpeechCpp.framework" \
  -output "${STAGE}"

rm -rf "${OUT}/SpeechCpp.xcframework"
mkdir -p "${OUT}"
cp -R "${STAGE}" "${OUT}/SpeechCpp.xcframework"
ditto -c -k --sequesterRsrc --keepParent "${OUT}/SpeechCpp.xcframework" "${OUT}/SpeechCpp.xcframework.zip"
(cd "${OUT}" && shasum -a 256 "SpeechCpp.xcframework.zip" > "SHA256SUMS")

echo "Built experimental speech.cpp 0.11.0 XCFramework at ${OUT}/SpeechCpp.xcframework"
