#!/bin/sh

set -e
set -x

ARCH="$1"

SOURCE_DIR="$2"
BUILD_DIR=$(echo "$(cd "$(dirname "$3")"; pwd -P)/$(basename "$3")")
OPENSSL_DIR="$4"

openssl_crypto_library="${OPENSSL_DIR}/lib/libcrypto.a"
options=""
options="$options -DOPENSSL_FOUND=1"
options="$options -DOPENSSL_CRYPTO_LIBRARY=${openssl_crypto_library}"
options="$options -DOPENSSL_INCLUDE_DIR=${OPENSSL_DIR}/src/include"
options="$options -DCMAKE_BUILD_TYPE=Release"
options="$options -DIOS_DEPLOYMENT_TARGET=13.0"

cd "$BUILD_DIR"

# Generate source files
# Build these host tools against the selected Xcode's macOS SDK. Without this, xcrun's
# default SDK can be the Command Line Tools one, which may be newer than the
# selected Xcode's linker understands (e.g. Xcode 26.2 on macOS 27).
HOST_SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
mkdir native-build
cd native-build
SDKROOT="$HOST_SDKROOT" cmake -DTD_GENERATE_SOURCE_FILES=ON ../td
SDKROOT="$HOST_SDKROOT" cmake --build . -- -j$(sysctl -n hw.ncpu)
cd ..

if [ "$ARCH" = "arm64" ]; then
  IOS_PLATFORMDIR="$(xcode-select -p)/Platforms/iPhoneOS.platform"
  IOS_SYSROOT=($IOS_PLATFORMDIR/Developer/SDKs/iPhoneOS*.sdk)
  export CFLAGS="-arch arm64 --target=arm64-apple-ios13.0 -miphoneos-version-min=13.0 -w"
elif [ "$ARCH" = "sim_arm64" ]; then
  IOS_PLATFORMDIR="$(xcode-select -p)/Platforms/iPhoneSimulator.platform"
  IOS_SYSROOT=($IOS_PLATFORMDIR/Developer/SDKs/iPhoneSimulator*.sdk)
  export CFLAGS="-arch arm64 --target=arm64-apple-ios13.0-simulator -miphonesimulator-version-min=13.0 -w"
elif [ "$ARCH" = "macos_arm64" ]; then
  IOS_PLATFORMDIR="$(xcode-select -p)/Platforms/MacOSX.platform"
  IOS_SYSROOT=($IOS_PLATFORMDIR/Developer/SDKs/MacOSX*.sdk)
  export CFLAGS="-arch arm64 --target=arm64-apple-macosx14.0 -mmacosx-version-min=14.0 -w"
else
  echo "Unsupported architecture $ARCH"
  exit 1
fi
export CXXFLAGS="$CFLAGS"

# Common build steps
mkdir build
cd build

touch toolchain.cmake
echo "set(CMAKE_SYSTEM_NAME Darwin)" >> toolchain.cmake
echo "set(CMAKE_SYSTEM_PROCESSOR aarch64)" >> toolchain.cmake
echo "set(CMAKE_C_COMPILER $(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang)" >> toolchain.cmake

cmake -G"Unix Makefiles" -DCMAKE_TOOLCHAIN_FILE=toolchain.cmake -DCMAKE_OSX_SYSROOT=${IOS_SYSROOT[0]} ../td $options
make tde2e -j$(sysctl -n hw.ncpu)
