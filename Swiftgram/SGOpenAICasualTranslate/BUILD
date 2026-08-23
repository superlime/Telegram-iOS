load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "SGOpenAICasualTranslate",
    module_name = "SGOpenAICasualTranslate",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        # Holds the shared API key and the two output-cleaning helpers, so the
        # chat-completions backends cannot drift apart.
        "//Swiftgram/SGOpenAITranslate:SGOpenAITranslate",
    ],
    visibility = [
        "//visibility:public",
    ],
)
