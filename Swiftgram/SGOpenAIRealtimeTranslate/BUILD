load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "SGOpenAIRealtimeTranslate",
    module_name = "SGOpenAIRealtimeTranslate",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        # The API key lives in SGOpenAITranslate's gitignored credentials file,
        # so both OpenAI backends are configured by pasting the key once.
        "//Swiftgram/SGOpenAITranslate:SGOpenAITranslate",
    ],
    visibility = [
        "//visibility:public",
    ],
)
