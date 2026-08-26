//
//  AppleIntelligenceUtils.swift
//  xLights-macOSLib
//
//  Created by Daniel Kulp on 9/13/25.
//  Copyright © 2025 Daniel Kulp. All rights reserved.
//

import Foundation
@_weakLinked import FoundationModels
import CoreGraphics
import ImageIO

@_weakLinked import ImagePlayground

#if os(macOS)
import AppKit
#else
import UIKit
#endif

@available(macOS 26.0, *)
struct DynObjCreator {
    let name: String
    var properties: [DynamicGenerationSchema.Property] = []
    
    mutating func addStringProperty(name: String) {
        let property = DynamicGenerationSchema.Property(
            name: name,
            schema: DynamicGenerationSchema(type: String.self)
        )
        properties.append(property)
    }
    mutating func addArrayProperty(name: String, customType: String) {
        let property = DynamicGenerationSchema.Property(
            name: name,
            schema: DynamicGenerationSchema (
                arrayOf: DynamicGenerationSchema(referenceTo: customType)
            )
        )
        properties.append(property)
    }
    var root: DynamicGenerationSchema {
        DynamicGenerationSchema(
          name: name,
          properties: properties
        )
    }
}


class AsyncStringResult: @unchecked Sendable {
    var result: String = ""
}

public func RunAppleIntelligencePrompt(_ prompt: String) -> String {
    if #available(macOS 26.0, *) {
        if let reason = appleIntelligenceUnavailableReason() {
            return reason
        }
        let semaphore = DispatchSemaphore(value: 0)
        let result: AsyncStringResult = .init()
        Task {
            defer {
                semaphore.signal()
            }
            do {
                let session = LanguageModelSession()
                let response = try await session.respond(to: prompt)
                result.result = response.content
            } catch {
                result.result = "Apple Intelligence error: \(error)"
            }
        }
        semaphore.wait()
        return result.result
    } else {
        return ""
    }
}

@available(macOS 26.0, *)
private func appleIntelligenceUnavailableReason() -> String? {
    // FoundationModels will crash (EXC_BAD_ACCESS) inside respond(to:) if
    // the system model isn't actually ready. Gate on availability so we
    // can return a clean message instead of a nil deref the catch can't
    // see.
    switch SystemLanguageModel.default.availability {
    case .available:
        return nil
    case .unavailable(.appleIntelligenceNotEnabled):
        return "Apple Intelligence is not enabled. Enable it in System Settings > Apple Intelligence & Siri."
    case .unavailable(.modelNotReady):
        return "Apple Intelligence model is not ready yet. It may still be downloading."
    case .unavailable(.deviceNotEligible):
        return "This device does not support Apple Intelligence."
    case .unavailable(let other):
        return "Apple Intelligence is unavailable: \(String(describing: other))"
    }
}

public func RunAppleIntelligenceGeneratePalette(_ prompt: String) -> String {
    let fullprompt = "xlights color palettes are 8 unique colors. Can you create a color palette that would represent the moods and imagery " + prompt + ". Avoid dark, near black colors."
    if #available(macOS 26.0, *) {
        if let reason = appleIntelligenceUnavailableReason() {
            return "{\"error\": \"\(reason)\"}"
        }
        let semaphore = DispatchSemaphore(value: 0)
        let result: AsyncStringResult = .init()
        Task {
            defer {
                semaphore.signal()
            }
            var colorPaletteBuilder = DynObjCreator(name: "ColorPalette")
            var color = DynObjCreator(name: "Color")
            color.addStringProperty(name: "Name")
            color.addStringProperty(name: "Hex Value")
            color.addStringProperty(name: "Description")
            colorPaletteBuilder.addArrayProperty(name: "Colors", customType: "Color")
            colorPaletteBuilder.addStringProperty(name: "Description")
            
            let colorPaletteDynamicSchema = colorPaletteBuilder.root
            do {
                let schema = try GenerationSchema(
                  root: colorPaletteDynamicSchema,
                  dependencies: [color.root]
                )
                let session = LanguageModelSession()
                let response = try await session.respond(to: fullprompt, schema: schema)
                result.result = response.content.jsonString;

            } catch let error as CustomDebugStringConvertible {
                result.result = "{\"error\": \"\(error.debugDescription)\"}";
            } catch let error as LocalizedError {
                let message = error.errorDescription ?? String(describing: error)
                result.result = "{\"error\": \"\(message)\"}";
            } catch {
                result.result = "{\"error\": \"\(error)\"}";
            }
        }
        semaphore.wait()
        return result.result
    }
    return "";
}

// Image generation goes through the system Image Playground sheet. The
// headless ImageCreator class it replaces was discontinued in macOS 27 /
// iOS 27 - it throws at runtime there and is gone from the SDK - so the
// user now drives the generation in Apple's own UI. We seed it with the
// prompt and style the xLights dialog collected, and the delegate hands
// back a file URL that we turn into a CGImage for the caller.
//
// One session object per presentation: it holds itself alive (`alive`)
// for as long as the sheet is up, because the view controller only keeps
// a weak reference to its delegate.
@available(macOS 15.4, iOS 18.4, *)
@MainActor
final class ImagePlaygroundSession: NSObject, ImagePlaygroundViewController.Delegate {
    private var completion: ((CGImage?, String?) -> Void)?
    private var alive: ImagePlaygroundSession?

#if os(macOS)
    private weak var parentWindow: NSWindow?
    private var sheetWindow: NSWindow?
#else
    private weak var presentedController: ImagePlaygroundViewController?
#endif

    func start(prompt: String,
               styleId: String,
               completion: @escaping (CGImage?, String?) -> Void) {
        self.completion = completion
        self.alive = self

        guard ImagePlaygroundViewController.isAvailable else {
            finish(nil, "Image Playground is not available on this device")
            return
        }

        let controller = ImagePlaygroundViewController()
        controller.delegate = self

        // What the user typed has to go in verbatim as its own concept.
        // Handing the sheet a block of style instructions instead makes it
        // extract concepts out of those - the subject is then dropped and
        // the picture comes back as whatever "bold outlines, flat colors"
        // suggests on its own. Each concept shows as a chip the user can
        // edit or delete, so keep them to what they asked for.
        var concepts: [ImagePlaygroundConcept] = []
        if !prompt.isEmpty {
            concepts.append(.text(prompt))
        } else {
            concepts.append(.text("Christmas tree"))
        }
        controller.concepts = concepts
        if let style = ImagePlaygroundStyle.all.first(where: { $0.id == styleId }) {
            controller.selectedGenerationStyle = style
        }

#if os(macOS)
        // wx windows have no contentViewController to present a sheet from,
        // so host the controller in a window of its own and run that as the
        // sheet instead.
        guard let parent = NSApp.keyWindow ?? NSApp.mainWindow else {
            finish(nil, "No window available to show Image Playground")
            return
        }
        let sheet = NSWindow(contentViewController: controller)
        parentWindow = parent
        sheetWindow = sheet
        parent.beginSheet(sheet)
#else
        guard let top = ImagePlaygroundSession.topViewController() else {
            finish(nil, "No window available to show Image Playground")
            return
        }
        presentedController = controller
        top.present(controller, animated: true)
#endif
    }

    private func finish(_ image: CGImage?, _ error: String?) {
        let callback = completion
        completion = nil

#if os(macOS)
        if let sheet = sheetWindow {
            parentWindow?.endSheet(sheet)
            sheetWindow = nil
        }
#else
        presentedController?.dismiss(animated: true)
        presentedController = nil
#endif

        callback?(image, error)
        alive = nil
    }

#if !os(macOS)
    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
            ?? scene?.windows.first?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
#endif

    func imagePlaygroundViewController(_ imagePlaygroundViewController: ImagePlaygroundViewController,
                                       didCreateImageAt imageURL: URL) {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            finish(nil, "Could not read the generated image")
            return
        }
        finish(image, nil)
    }

    func imagePlaygroundViewControllerDidCancel(_ imagePlaygroundViewController: ImagePlaygroundViewController) {
        finish(nil, "Image generation was cancelled")
    }
}

@objcMembers public class ImagesAsyncCaller: NSObject {
    // Called from the C++ bridge, possibly off the main thread. Presenting
    // the sheet is main-thread work, and the callback fires once the user
    // finishes or cancels in Apple's UI.
    public func generateImages(prompt: String,
                               style: String,
                               completionHandler: @escaping @Sendable (CGImage?, String?) -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if #available(macOS 15.4, iOS 18.4, *) {
                    ImagePlaygroundSession().start(prompt: prompt,
                                                   styleId: style,
                                                   completion: completionHandler)
                } else {
                    completionHandler(nil, "Image generation requires macOS 15.4 or later")
                }
            }
        }
    }
}
