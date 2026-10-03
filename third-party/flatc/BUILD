
genrule(
    name = "flatc",
    srcs = [
        "@flatbuffers_zip//file",
        "@cmake_tar_gz//file",
    ],
    cmd_bash =
"""
set -x
    core_count=`PATH="$$PATH:/usr/sbin" sysctl -n hw.logicalcpu`
    BUILD_DIR="$(RULEDIR)/build"
    rm -rf "$$BUILD_DIR"
    mkdir -p "$$BUILD_DIR"

    CMAKE_DIR="$$(pwd)/$$BUILD_DIR/cmake"
    rm -rf "$$CMAKE_DIR"
    mkdir -p "$$CMAKE_DIR"
    tar -xf "$(location @cmake_tar_gz//file)" -C "$$CMAKE_DIR"
    
    # Build host tools against the selected Xcode's macOS SDK. Without this, xcrun's
    # default SDK can be the Command Line Tools one, which may be newer than the
    # selected Xcode's linker understands (e.g. Xcode 26.2 on macOS 27).
    export SDKROOT="$$(xcrun --sdk macosx --show-sdk-path)"

    tar -xzf "$(location @flatbuffers_zip//file)" --directory "$$BUILD_DIR"
    pushd "$$BUILD_DIR/flatbuffers-24.12.23"
    mkdir build
    cd build
    PATH="$$CMAKE_DIR/cmake-4.1.2-macos-universal/CMake.app/Contents/bin:$$PATH" cmake .. -DCMAKE_BUILD_TYPE=Release -DFLATBUFFERS_BUILD_TESTS=0 -DFLATBUFFERS_INSTALL=0 -DFLATBUFFERS_BUILD_FLATLIB=0 -DFLATBUFFERS_STATIC_FLATC=0
    make -j $$core_count
    popd

    cp "$$BUILD_DIR/flatbuffers-24.12.23/build/flatc" "$(location flatc_bin)"
""",
    outs = [
        "flatc_bin",
    ],
    visibility = [
        "//visibility:public",
    ]
)
