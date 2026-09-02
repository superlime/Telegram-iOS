load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "SGOpenAILunaTranslate",
    module_name = "SGOpenAILunaTranslate",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        # Shared API key + output-cleaning helpers.
        "//Swiftgram/SGOpenAITranslate:SGOpenAITranslate",
        # Shared context type, transcript formatter and prompt wording.
        "//Swiftgram/SGOpenAICasualTranslate:SGOpenAICasualTranslate",
    ],
    visibility = [
        "//visibility:public",
    ],
)
