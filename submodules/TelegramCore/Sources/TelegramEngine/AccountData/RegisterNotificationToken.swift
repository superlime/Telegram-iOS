import Foundation
import SwiftSignalKit
import Postbox
import TelegramApi


public enum NotificationTokenType {
    case aps(encrypt: Bool)
    case voip
}

func _internal_unregisterNotificationToken(account: Account, token: Data, type: NotificationTokenType, otherAccountUserIds: [PeerId.Id]) -> Signal<Never, NoError> {
    let mappedType: Int32
    switch type {
        case .aps:
            mappedType = 1
        case .voip:
            mappedType = 9
    }
    return account.network.request(Api.functions.account.unregisterDevice(tokenType: mappedType, token: hexString(token), otherUids: otherAccountUserIds.map({ $0._internalGetInt64Value() })))
    |> retryRequest
    |> ignoreValues
}

func _internal_registerNotificationToken(account: Account, token: Data, type: NotificationTokenType, sandbox: Bool, otherAccountUserIds: [PeerId.Id], excludeMutedChats: Bool) -> Signal<Bool, NoError> {
    return masterNotificationsKey(account: account, ignoreDisabled: false)
    |> mapToSignal { masterKey -> Signal<Bool, NoError> in
        let mappedType: Int32
        var keyData = Data()
        switch type {
            case let .aps(encrypt):
                mappedType = 1
                if encrypt {
                    keyData = masterKey.data
                }
            case .voip:
                mappedType = 9
                keyData = masterKey.data
        }
        var flags: Int32 = 0
        if excludeMutedChats {
            flags |= 1 << 0
        }
        // MARK: Swiftgram
        // The `catch` below reports success for every error except
        // TOKEN_WAS_INVALIDATED, so a server-side push misconfiguration is
        // completely silent: the app believes it registered and no notification
        // ever arrives. Log the outcome so APP_PUSH_CERT_MISSING and similar are
        // visible. Turn on Settings > Swiftgram > Debug > Logging to capture this
        // in a release/TestFlight build, then search the log for "PushToken".
        let tokenPrefix = String(hexString(token).prefix(8))
        Logger.shared.log("PushToken", "registerDevice: type=\(mappedType) sandbox=\(sandbox) encrypted=\(!keyData.isEmpty) excludeMuted=\(excludeMutedChats) tokenLength=\(token.count) tokenPrefix=\(tokenPrefix)")

        return account.network.request(Api.functions.account.registerDevice(flags: flags, tokenType: mappedType, token: hexString(token), appSandbox: sandbox ? .boolTrue : .boolFalse, secret: Buffer(data: keyData), otherUids: otherAccountUserIds.map({ $0._internalGetInt64Value() })))
        |> map { _ -> Bool in
            Logger.shared.log("PushToken", "registerDevice OK: type=\(mappedType) sandbox=\(sandbox) tokenPrefix=\(tokenPrefix)")
            return true
        }
        |> `catch` { error -> Signal<Bool, NoError> in
            Logger.shared.log("PushToken", "registerDevice FAILED: type=\(mappedType) sandbox=\(sandbox) tokenPrefix=\(tokenPrefix) error=\(error.errorDescription ?? "unknown")")
            if error.errorDescription == "TOKEN_WAS_INVALIDATED" {
                return .single(false)
            } else {
                return .single(true)
            }
        }
    }
}
