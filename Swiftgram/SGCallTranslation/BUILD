load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "SGCallTranslation",
    module_name = "SGCallTranslation",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/Postbox:Postbox",
        "//submodules/TelegramCore:TelegramCore",
        "//Swiftgram/SGSimpleSettings:SGSimpleSettings",
        "//Swiftgram/SGModulateSTT:SGModulateSTT",
        "//Swiftgram/SGOpenAILunaTranslate:SGOpenAILunaTranslate",
    ],
    visibility = [
        "//visibility:public",
    ],
)
