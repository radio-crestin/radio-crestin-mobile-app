import AVFoundation

/// Keeps tvOS from suspending the app in the background while the listener
/// wants a live station that is not playing.
///
/// With the audio background mode, tvOS keeps a background app running
/// only while it plays audio. During an outage AVPlayer plays nothing, and
/// between retry rounds it holds no item at all, so tvOS would suspend the
/// app, and with it the supervision timer and the network watcher that
/// bring the station back: it would stay silent until the listener opened
/// the app again. The keeper renders silence meanwhile, as the iOS app's
/// `SilenceKeeper` does during its reconnects.
///
/// It renders through `AVAudioEngine` rather than a second AVPlayer: there
/// is no asset to ship, and the output runs for as long as the engine does.
@MainActor
final class BackgroundAudioKeeper {
    /// Built on the first start, not with the keeper: creating the engine
    /// and its player node looks up the system's audio components, 15 to
    /// 23 ms on the main thread, and the keeper is created inside the
    /// app's first frame. Most sessions never start it.
    private var output: SilentOutput?
    private var hasReportedFailure = false

    /// Starts or stops the silence. Repeating a call does nothing, except
    /// that a wanted engine the system stopped (an output change, an
    /// interruption) starts again.
    func setRunning(_ running: Bool) {
        if running {
            start()
        } else if let output, output.engine.isRunning {
            output.source.stop()
            output.engine.stop()
        }
    }

    private func start() {
        do {
            let output = try self.output ?? SilentOutput()
            self.output = output
            guard !output.engine.isRunning else { return }
            try output.engine.start()
            // Clears a loop the system's stop left scheduled.
            output.source.stop()
            output.source.scheduleBuffer(
                output.silence, at: nil, options: .loops
            )
            output.source.play()
        } catch {
            // The next look of the engine tries again; one report says
            // the keeper cannot run on this device.
            guard !hasReportedFailure else { return }
            hasReportedFailure = true
            Analytics.captureError(error, context: "background_keeper_start")
        }
    }

    /// The engine, with a player node wired to its mixer, and the looped
    /// buffer of silence the node plays.
    private struct SilentOutput {
        let engine = AVAudioEngine()
        let source = AVAudioPlayerNode()
        let silence: AVAudioPCMBuffer

        /// Sample rate of the silent buffer; the mixer converts it to the
        /// output's, so any common rate does.
        private static let sampleRate: Double = 44_100

        /// Length of the silent buffer. It loops, so its length only sets
        /// how much memory it takes: a tenth of a second is 17 KB.
        private static let bufferDuration: Double = 0.1

        init() throws {
            let frames = AVAudioFrameCount(
                Self.sampleRate * Self.bufferDuration
            )
            guard let format = AVAudioFormat(
                      standardFormatWithSampleRate: Self.sampleRate,
                      channels: 1
                  ),
                  let buffer = AVAudioPCMBuffer(
                      pcmFormat: format, frameCapacity: frames
                  ),
                  let samples = buffer.floatChannelData?[0]
            else { throw KeeperError.noBuffer }
            buffer.frameLength = frames
            samples.update(repeating: 0, count: Int(frames))
            engine.attach(source)
            engine.connect(source, to: engine.mainMixerNode, format: format)
            silence = buffer
        }
    }

    private enum KeeperError: LocalizedError {
        case noBuffer

        var errorDescription: String? {
            "Could not allocate the background keeper's silent buffer"
        }
    }
}
