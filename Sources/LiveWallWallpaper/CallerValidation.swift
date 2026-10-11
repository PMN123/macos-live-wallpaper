// LiveWallWallpaper — validates the identity of processes connecting to the extension.
//
// Adapted from Phosphene (https://github.com/kageroumado/phosphene), MIT License, © 2026 kageroumado
// Source: PhospheneExtension/CallerValidation.swift at commit db03edf. See THIRD_PARTY_NOTICES.md.
//
// The exported handler drives rendering and snapshot work, so connections are only
// served to Apple's wallpaper host. The peer's code signature is derived from its
// audit token (never the reusable PID) and must be an Apple-anchored binary.
//
// Posture: reject callers positively identified as non-Apple. Accept Apple binaries,
// noting when the signer isn't WallpaperAgent (the Settings surfaces are Apple-hosted
// too). Fail *open* only when peer identity genuinely can't be obtained, so an OS
// change to the audit-token SPI degrades instead of bricking the wallpaper.

import Foundation
import Security
import WallpaperPrivate

enum CallerValidation {
    static func isAcceptable(_ connection: NSXPCConnection) -> Bool {
        guard connection.responds(to: NSSelectorFromString("auditToken")) else {
            extensionLog("  [Caller] auditToken SPI unavailable — accepting (fail-open)")
            return true
        }

        var token = connection.auditToken
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }
        let attrs = [kSecGuestAttributeAudit: tokenData] as CFDictionary

        var code: SecCode?
        let status = SecCodeCopyGuestWithAttributes(nil, attrs, [], &code)
        guard status == errSecSuccess, let code else {
            extensionLog("  [Caller] could not derive peer SecCode (status \(status)) — accepting (fail-open)")
            return true
        }

        guard let appleReq = requirement("anchor apple") else {
            extensionLog("  [Caller] could not build anchor-apple requirement — accepting (fail-open)")
            return true
        }

        let appleStatus = SecCodeCheckValidity(code, SecCSFlags(rawValue: 0), appleReq)
        guard appleStatus == errSecSuccess else {
            extensionError("  [Caller] REJECTED non-Apple caller (status \(appleStatus))")
            return false
        }

        if let agentReq = requirement("identifier \"com.apple.wallpaper.agent\""),
           SecCodeCheckValidity(code, SecCSFlags(rawValue: 0), agentReq) != errSecSuccess {
            extensionLog("  [Caller] Apple caller is not WallpaperAgent — accepting with note")
        }
        return true
    }

    private static func requirement(_ text: String) -> SecRequirement? {
        var req: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, SecCSFlags(rawValue: 0), &req) == errSecSuccess else {
            return nil
        }
        return req
    }
}
