//
//  AppleSpeechRecognizer.swift
//  xLights-Apple-core
//
//  SFSpeechRecognizer wrapper for chunked audio-file transcription.
//  Used by AppleIntelligence's SPEECH2TEXT capability to turn the
//  loaded sequence's audio (or, ideally, its isolated vocals stem)
//  into a timing track of word/start/end triples.
//
//  Recognition request type: always SFSpeechURLRecognitionRequest.
//  We tried SFSpeechAudioBufferRecognitionRequest (one giant append +
//  immediate endAudio()) first and it silently dropped the leading
//  portion of long inputs — the buffer path's voice-activity model
//  doesn't lock in without streaming context. URL-based requests
//  read the file at the framework's own pace and produce results
//  from frame 0.
//
//  Chunking algorithm — overlap-with-trim:
//
//    Each chunk owns a "body" — the audio whose words it's
//    responsible for transcribing. Bodies butt edge-to-edge with no
//    overlap (0..13, 13..26, 26..end), so every word in the file
//    gets attributed to exactly one chunk's body.
//
//    The audio handed to the recognizer for each chunk extends
//    `chunkOverlapSeconds` (1 s) past the body on each side. This
//    pre-/post-context guarantees that words straddling a body
//    boundary sit comfortably inside one chunk's audio range and
//    get recognized cleanly there. The outer chunks omit pre- /
//    post-context where there's no audio to extend into.
//
//    After recognition, segments from each chunk are filtered:
//    keep only those whose midpoint falls inside the body. So a
//    word at file time 12.8..13.2 s (midpoint 13.0) lands in the
//    13..26 body, not the 0..13 body — and chunk 1 had clean
//    audio for it because 13 s is a full second inside its 12..27 s
//    audio range.
//
//    `chunkBodySeconds` is intentionally short (13 s). SFSpeech's
//    on-device recognizer also fails to lock in on long single-shot
//    inputs (observed: a 35 s narration silently lost its first
//    22 s in one request). Smaller windows + per-chunk fresh
//    recognizer state produce results from each chunk's first
//    frame.
//
//  Per-chunk failures are non-fatal: a chunk of silence, music, or
//  applause legitimately produces "no speech detected"
//  (kAFAssistantErrorDomain 1110). We capture the most recent
//  per-chunk error and continue with the next body, only surfacing
//  the error if the entire run produced zero words.
//
//  Other notes:
//    - Forced to on-device recognition (no audio leaves the device)
//      both for privacy and so it works offline.
//    - Permission prompt is gated by NSSpeechRecognitionUsageDescription
//      in the host app's Info.plist.
//    - Per-chunk audio is written to a temp .caf in the source
//      file's own format (avoids resampling artefacts) and deleted
//      after recognition completes.
//
//  Concurrency model: this file deliberately uses plain GCD +
//  DispatchSemaphore instead of Swift Concurrency (`async`/`await`,
//  `withCheckedContinuation`). Wrapping SFSpeech's completion-handler
//  APIs in `withChecked*Continuation` crashed with EXC_BAD_ACCESS
//  under Swift 6 strict concurrency on macOS Tahoe. The semaphore
//  pattern sidesteps that entirely. The caller (recognizeAudioFile)
//  spawns its own background dispatch so blocking on the semaphore
//  doesn't tie up the calling thread.
//

import Foundation
import AVFoundation
import Speech

@objcMembers public class AppleSpeechRecognizer: NSObject {

    /// Asynchronous file-based transcription. Calls `completion`
    /// exactly once, on an arbitrary thread, with parallel arrays
    /// (words, startMS, endMS) plus an error string. On success
    /// `error` is empty; on failure the arrays are empty and `error`
    /// carries the message.
    public class func recognizeAudioFile(
        atPath path: String,
        localeIdentifier: String,
        completion: @escaping @Sendable ([String], [NSNumber], [NSNumber], String) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = runRecognition(path: path, localeIdentifier: localeIdentifier)
            completion(result.words, result.starts, result.ends, result.error)
        }
    }

    // MARK: - Internal pipeline

    private struct ParallelArrays {
        var words: [String] = []
        var starts: [NSNumber] = []
        var ends: [NSNumber] = []
        var error: String = ""
    }

    /// "Body" duration: the audio that this chunk is responsible
    /// for transcribing. Adjacent chunks' bodies butt up against
    /// each other with no overlap.
    private static let chunkBodySeconds: Double = 13.0

    /// Each chunk's audio extends `chunkOverlapSeconds` past its
    /// body on each side, giving the recognizer warm-up context
    /// before the body and post-context after — so words that
    /// straddle a body boundary get clean recognition from the
    /// chunk that owns them. After recognition we keep only
    /// segments whose midpoint lands inside the body, so each word
    /// appears exactly once and gets the chunk that has it well
    /// inside its audio.
    ///
    /// SFSpeech's on-device recognizer also fails to lock in on
    /// long single-shot inputs (observed: 35 s narration silently
    /// lost its first 22 s). Keeping chunks small avoids that.
    private static let chunkOverlapSeconds: Double = 1.0

    private static func runRecognition(path: String, localeIdentifier: String) -> ParallelArrays {
        var out = ParallelArrays()

        let auth = requestAuthorization()
        switch auth {
        case .authorized: break
        case .denied:
            out.error = "Speech recognition permission denied"
            return out
        case .restricted:
            out.error = "Speech recognition is restricted on this device"
            return out
        case .notDetermined:
            out.error = "Speech recognition permission was not granted"
            return out
        @unknown default:
            out.error = "Unknown speech recognition authorization state"
            return out
        }

        let locale = localeIdentifier.isEmpty
            ? Locale(identifier: "en-US")
            : Locale(identifier: localeIdentifier)
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            out.error = "No recognizer available for locale \(locale.identifier)"
            return out
        }
        guard recognizer.isAvailable else {
            out.error = "Speech recognizer is not currently available"
            return out
        }
        guard recognizer.supportsOnDeviceRecognition else {
            // We refuse to fall back to server-side recognition —
            // the audio belongs to the user, not Apple's servers.
            out.error = "On-device speech recognition is not supported on this device"
            return out
        }

        // Open the audio file up front so we can compute the
        // total duration without going through AVURLAsset.duration
        // (deprecated in iOS 16 / macOS 13 in favour of the async
        // load(.duration); we don't want to pollute this synchronous
        // GCD pipeline with async/await).
        let url = URL(fileURLWithPath: path)
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            out.error = "Couldn't open audio file: \(error.localizedDescription)"
            return out
        }

        let format = audioFile.processingFormat
        let totalFrames = audioFile.length
        let sampleRate = format.sampleRate
        if totalFrames <= 0 || sampleRate <= 0 {
            out.error = "Audio file is empty or has an invalid sample rate"
            return out
        }
        let totalDurationSec = Double(totalFrames) / sampleRate

        // Short files: single SFSpeechURLRecognitionRequest with the
        // original URL. No chunking, no overlap-trim, no temp file —
        // SFSpeech reads the file directly.
        if totalDurationSec <= chunkBodySeconds {
            let (segs, err) = recognizeFile(recognizer: recognizer,
                                              url: url,
                                              startOffsetMS: 0)
            if let err = err {
                out.error = "Recognition failed: \(err.localizedDescription)"
                return out
            }
            appendSegments(segs, into: &out)
            return out
        }

        // Long files: read via AVAudioFile (already opened above),
        // write each chunk's audio (body + leading + trailing
        // context) to a temp WAV, recognise it, then keep only
        // segments whose midpoint is in the body's time range.
        // Bodies butt up edge-to-edge so every word is attributed
        // to exactly one chunk.

        // Last per-chunk recognition error. We don't fail the whole
        // run on individual chunk errors (a chunk of silence or
        // music legitimately produces "no speech detected") — but
        // if every chunk fails we use this to explain why the
        // overall result is empty.
        var lastChunkError: Error? = nil

        var bodyStartSec: Double = 0
        while bodyStartSec < totalDurationSec {
            let bodyEndSec = min(bodyStartSec + chunkBodySeconds, totalDurationSec)
            // Audio extent: pre-context (if not first chunk) + body
            // + post-context (if not last chunk). The recognizer
            // sees a few seconds more than we'll keep, so words at
            // the body boundaries get clean recognition.
            let audioStartSec = max(0, bodyStartSec - chunkOverlapSeconds)
            let audioEndSec   = min(totalDurationSec, bodyEndSec + chunkOverlapSeconds)

            let startFrame = AVAudioFramePosition(audioStartSec * sampleRate)
            let endFrame   = AVAudioFramePosition(audioEndSec * sampleRate)
            let frameCountI64 = endFrame - startFrame
            if frameCountI64 <= 0 { break }
            let frameCount = AVAudioFrameCount(frameCountI64)

            audioFile.framePosition = startFrame
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                 frameCapacity: frameCount) else {
                out.error = "Failed to allocate audio buffer for chunk at \(audioStartSec)s"
                return out
            }
            do {
                try audioFile.read(into: buffer, frameCount: frameCount)
            } catch {
                out.error = "Audio read failed at \(audioStartSec)s: \(error.localizedDescription)"
                return out
            }

            // Temp .caf using the source file's own format — avoids
            // resampling artefacts at the recognizer's input.
            let tempName = "xlights_speech_chunk_\(UUID().uuidString).caf"
            let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(tempName)
            do {
                let tempFile = try AVAudioFile(forWriting: tempURL,
                                                settings: format.settings,
                                                commonFormat: format.commonFormat,
                                                interleaved: format.isInterleaved)
                try tempFile.write(from: buffer)
            } catch {
                out.error = "Couldn't write chunk audio: \(error.localizedDescription)"
                return out
            }

            let audioStartMS = Int(audioStartSec * 1000.0)
            let (segs, chunkErr) = recognizeFile(recognizer: recognizer,
                                                   url: tempURL,
                                                   startOffsetMS: audioStartMS)
            try? FileManager.default.removeItem(at: tempURL)

            // Per-chunk failures are non-fatal. The most common one
            // is "no speech detected" (kAFAssistantErrorDomain 1110)
            // when the body is silence, music, or applause — that's
            // a real outcome for some sequences (intro/outro) and
            // we want to keep transcribing the chunks that *do* have
            // speech. We capture the last error so we can surface it
            // if the whole file ends up producing zero words.
            if let chunkErr = chunkErr {
                lastChunkError = chunkErr
                bodyStartSec = bodyEndSec
                continue
            }

            // Keep only segments whose midpoint lies inside the
            // body. Boundary words land in whichever chunk has them
            // most-centred, so a word that straddles 13 s gets
            // attributed (and recognized cleanly) by exactly one
            // chunk.
            let bodyStartMS = Int(bodyStartSec * 1000.0)
            let bodyEndMS   = Int(bodyEndSec   * 1000.0)
            for s in segs {
                let mid = (s.1 + s.2) / 2
                if mid >= bodyStartMS && mid < bodyEndMS {
                    out.words.append(s.0)
                    out.starts.append(NSNumber(value: s.1))
                    out.ends.append(NSNumber(value: s.2))
                }
            }

            bodyStartSec = bodyEndSec
        }

        // Empty result + a chunk-level error means every chunk
        // failed — usually denied permission, recognizer
        // unavailable, or the audio file genuinely contains no
        // recognisable speech. Surface the last error so the
        // caller has something useful to display. Empty result + no
        // errors falls through to a clean empty timing track.
        if out.words.isEmpty, let err = lastChunkError {
            out.error = "No speech recognised: \(err.localizedDescription)"
        }

        return out
    }

    private static func appendSegments(_ segs: [(String, Int, Int)],
                                        into out: inout ParallelArrays) {
        for s in segs {
            out.words.append(s.0)
            out.starts.append(NSNumber(value: s.1))
            out.ends.append(NSNumber(value: s.2))
        }
    }

    /// Mutable status holder for the GCD-based prompt path. Class +
    /// @unchecked Sendable is the standard way to hand a single
    /// scalar across the GCD ↔ Swift Concurrency boundary without
    /// tripping Swift 6 strict-mode capture rules.
    private final class AuthBox: @unchecked Sendable {
        var value: SFSpeechRecognizerAuthorizationStatus = .notDetermined
    }

    private static func requestAuthorization() -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        if current != .notDetermined {
            return current
        }
        let sem = DispatchSemaphore(value: 0)
        let box = AuthBox()
        SFSpeechRecognizer.requestAuthorization { status in
            box.value = status
            sem.signal()
        }
        sem.wait()
        return box.value
    }

    /// Holder for one URL-recognition's result. Same pattern as
    /// `AuthBox`: a class lets us share state between SFSpeech's
    /// callback and the semaphore-blocked caller without strict-mode
    /// capture-rule headaches.
    private final class ChunkResultBox: @unchecked Sendable {
        var segments: [(String, Int, Int)] = []
        var error: Error? = nil
    }

    private static func recognizeFile(
        recognizer: SFSpeechRecognizer,
        url: URL,
        startOffsetMS: Int
    ) -> ([(String, Int, Int)], Error?) {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation

        let sem = DispatchSemaphore(value: 0)
        let box = ChunkResultBox()
        let offset = startOffsetMS

        // The recognition task is held implicitly by the result
        // handler; releasing it would cancel recognition.
        _ = recognizer.recognitionTask(with: request) { result, error in
            if let error = error {
                box.error = error
                sem.signal()
                return
            }
            guard let result = result, result.isFinal else { return }

            // Map SFTranscriptionSegments to (word, startMS, endMS).
            // segment.timestamp is the offset within THIS request's
            // audio in seconds; combine with offset for file-relative
            // timing.
            box.segments = result.bestTranscription.segments.map { seg -> (String, Int, Int) in
                let s = offset + Int(seg.timestamp * 1000.0)
                let e = offset + Int((seg.timestamp + seg.duration) * 1000.0)
                return (seg.substring, s, e)
            }
            sem.signal()
        }

        sem.wait()
        return (box.segments, box.error)
    }
}
