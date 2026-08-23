load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "SGTranslationCompare",
    module_name = "SGTranslationCompare",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        # No -warnings-as-errors: SwiftUI + availability-gated Translation code
        # produces warnings the rest of the SwiftUI modules (SGSwiftUI, SGPayWall)
        # also tolerate.
    ],
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/Display:Display",
        "//submodules/LegacyUI:LegacyUI",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/AccountContext:AccountContext",
        "//Swiftgram/SGSwiftUI:SGSwiftUI",
        "//Swiftgram/SGStrings:SGStrings",
        "//Swiftgram/SGSimpleSettings:SGSimpleSettings",
        "//Swiftgram/SGGTranslate:SGGTranslate",
        "//Swiftgram/SGAzureTranslate:SGAzureTranslate",
        "//Swiftgram/SGOpenAITranslate:SGOpenAITranslate",
        "//Swiftgram/SGOpenAIRealtimeTranslate:SGOpenAIRealtimeTranslate",
    ],
    visibility = [
        "//visibility:public",
    ],
)
