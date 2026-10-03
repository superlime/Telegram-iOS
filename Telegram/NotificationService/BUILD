load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_configuration//:variables.bzl", "telegram_notification_filtering_entitled")

sgdeps = [
    "//Swiftgram/SGAppGroupIdentifier:SGAppGroupIdentifier"
]

swift_library(
    name = "NotificationServiceExtensionLib",
    module_name = "NotificationServiceExtensionLib",
    srcs = glob([
        "Sources/*.swift",
    ]),
    # Set when the extension's provisioning profile grants com.apple.developer.usernotifications.filtering.
    copts = ["-DNOTIFICATION_FILTERING_ENTITLED"] if telegram_notification_filtering_entitled else [],
    deps = sgdeps + [
        "//submodules/Postbox:Postbox",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/BuildConfig:BuildConfig",
        "//submodules/MtProtoKit:MtProtoKit",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/EncryptionProvider:EncryptionProvider",
        "//submodules/AppLockState:AppLockState",
        "//submodules/NotificationsPresentationData:NotificationsPresentationData",
        "//submodules/TelegramUIPreferences:TelegramUIPreferences",
        "//submodules/OpenSSLEncryptionProvider:OpenSSLEncryptionProvider",
        "//submodules/WebPBinding:WebPBinding",
        "//submodules/rlottie:RLottieBinding",
        "//submodules/GZip:GZip",
        "//submodules/PersistentStringHash:PersistentStringHash",
        "//submodules/Utils/RangeSet",
        "//submodules/Media/ConvertOpusToAAC",
    ],
    visibility = [
        "//visibility:public",
    ],
)
