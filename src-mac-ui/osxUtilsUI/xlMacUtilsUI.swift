//
//  xlMacUtilsUI.swift
//  xLights
//
//  UI-specific macOS utilities.  Depends on AppKit (NSApp, NSScreen, etc.)
//  Core-safe utilities live in xlAppleUtils.swift.
//

import Foundation
import AppKit

// MARK: - Screen / Display

public func xlOSGetMainScreenContentScaleFactor() -> Double {
    var maxScale: Double = 1.0

    for screen in NSScreen.screens {
        let scale = Double(screen.backingScaleFactor)
        if scale > maxScale {
            maxScale = scale
        }
    }

    return maxScale
}

// MARK: - Color Adjustment

private func adjustColorToDeviceColorspaceInternal(_ color: NSColor) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
    var result: (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) = (0, 0, 0, 255)
    MainActor.assumeIsolated {
        if #available(macOS 11.0, *) {
            NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
                if let deviceColor = color.usingColorSpace(.deviceRGB) {
                    result = (UInt8(deviceColor.redComponent * 255),
                              UInt8(deviceColor.greenComponent * 255),
                              UInt8(deviceColor.blueComponent * 255),
                              UInt8(deviceColor.alphaComponent * 255))
                } else {
                    result = (UInt8(color.redComponent * 255),
                              UInt8(color.greenComponent * 255),
                              UInt8(color.blueComponent * 255),
                              UInt8(color.alphaComponent * 255))
                }
            }
        } else {
            if let deviceColor = color.usingColorSpace(.deviceRGB) {
                result = (UInt8(deviceColor.redComponent * 255),
                          UInt8(deviceColor.greenComponent * 255),
                          UInt8(deviceColor.blueComponent * 255),
                          UInt8(deviceColor.alphaComponent * 255))
            } else {
                result = (UInt8(color.redComponent * 255),
                          UInt8(color.greenComponent * 255),
                          UInt8(color.blueComponent * 255),
                          UInt8(color.alphaComponent * 255))
            }
        }
    }
    return result
}
public func adjustColorToDeviceColorspace(_ color: NSColor) -> UInt32{
    let result = adjustColorToDeviceColorspaceInternal(color);
    var r : UInt32;
    r = UInt32(result.blue)
    r |= UInt32(result.alpha) << 24
    r |= UInt32(result.red) << 16
    r |= UInt32(result.green) << 8
    return r;
}

// MARK: - Input Events

public func isMouseEventFromTouchpad() -> Bool {
    MainActor.assumeIsolated {
        guard let event = NSApp.currentEvent else { return false }
        return event.momentumPhase != []
            || event.phase != []
    }
}

// MARK: - Clipboard

public func getOSFormattedClipboardData() -> String {
    let pasteboard = NSPasteboard.general

    if let string = pasteboard.string(forType: .string) {
        return string
    }

    return ""
}

// MARK: - Button Appearance

public func setButtonBackground(_ button: NSButton, color: NSColor, transparent: Bool, bgType: Int) {
    MainActor.assumeIsolated {
        if transparent {
            button.bezelStyle = .push
            button.bezelColor = nil
        } else {
            button.bezelStyle = .push

            if bgType == 1 {
                button.isBordered = false
                button.wantsLayer = true

                if let layer = button.layer {
                    layer.backgroundColor = color.cgColor
                    layer.cornerRadius = 6
                    layer.borderWidth = 1
                    layer.borderColor = color.cgColor
                }
            } else {
                button.bezelColor = color
            }
        }

        button.needsDisplay = true
    }
}

// MARK: - Full Disk Access

func isSIPDisabled() -> Bool {
    let process = Process()
    process.launchPath = "/usr/bin/csrutil"
    process.arguments = ["status"]

    let pipe = Pipe()
    process.standardOutput = pipe

    do {
        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: data, encoding: .utf8) {
            return output.contains("System Integrity Protection status: disabled")
        }
    } catch {
        return false
    }
    return false
}

public func hasFullDiskAccess() -> Bool {
    let protectedPath = "/Library/Application Support/com.apple.TCC/"
    let fileManager = FileManager.default

    do {
        // Attempt to get contents of a directory requiring FDA
        _ = try fileManager.contentsOfDirectory(atPath: protectedPath)

        // If SIP is disabled, the above would allow access even if xLights doesn't have full disk access
        // We'll check if SIP is disabled and return false to avoid the semi-false possitive
        if isSIPDisabled() {
            return false
        }
        return true // If no error, FDA is likely granted
    } catch let error as NSError {
        // Check for specific error code indicating permission denied
        if error.code == NSFileReadNoPermissionError {
            return false // FDA not granted
        } else {
            // Handle other potential errors, or assume FDA not granted for simplicity
            return false
        }
    }
}
