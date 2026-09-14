//
//  GuidanceTone.swift
//  ObjectTrackingUpdates
//

#if os(visionOS)
import AVFAudio
import Foundation
import RealityKit
import Synchronization

/// A guidance cue synthesized live: a tone switched on and off in pulses,
/// whose pulse rate and pitch the guidance engine sets from a distance. A
/// pulse rate of zero is a continuous tone. It plays from whatever entity
/// starts it, so it is spatial like a file would be.
///
/// The render handler runs on the audio thread. The engine writes the two
/// parameters from the main actor and the handler reads them, and the
/// handler keeps its own oscillator state between calls, all through
/// atomics: nothing locks or allocates on the audio thread, which Apple's
/// `Audio.GeneratorRenderHandler` documentation requires.
nonisolated final class GuidanceTone: Sendable {
    /// The tone's timbre, so two cues read apart even at the same pitch.
    enum Waveform: Sendable {
        /// Pure, soft.
        case sine
        /// Odd harmonics on top: brighter, edgier.
        case triangle
    }

    /// RealityKit renders generator audio at this rate, in `Float32`
    /// (`Audio.GeneratorRenderHandler` documentation).
    private static let sampleRate = 48_000.0

    /// Peak sample value; the source entity's spatial gain does the rest.
    private static let amplitude = 0.8

    /// Pulses per second. Zero plays a continuous tone.
    let pulsesPerSecond: Atomic<Double>

    /// The tone's frequency, in hertz.
    let pitch: Atomic<Double>

    private let waveform: Waveform

    /// The fraction of each pulse period the tone is on: short pips or
    /// long beeps.
    private let dutyCycle: Double

    /// The tone ramps over this long at each pulse edge: longer is rounder,
    /// shorter is sharper; either way the gate doesn't click.
    private let rampSeconds: Double

    // Oscillator state, read and written only by the render handler, once
    // per render call rather than per sample.
    private let tonePhase = Atomic<Double>(0)
    private let pulsePhase = Atomic<Double>(0)
    private let envelope = Atomic<Double>(0)

    init(waveform: Waveform,
         dutyCycle: Double,
         rampSeconds: Double,
         pulsesPerSecond: Double,
         pitch: Double)
    {
        self.waveform = waveform
        self.dutyCycle = dutyCycle
        self.rampSeconds = rampSeconds
        self.pulsesPerSecond = Atomic(pulsesPerSecond)
        self.pitch = Atomic(pitch)
    }

    /// Builds the tone's playback on `entity` without starting it, so the
    /// setup cost lands at a quiet moment and the first `play()` is
    /// instant. Keep the controller: audio stops when it is released.
    @MainActor
    func prepare(on entity: Entity) throws -> AudioGeneratorController {
        let configuration = AudioGeneratorConfiguration(layoutTag: kAudioChannelLayoutTag_Mono)

        return try entity.prepareAudio(configuration: configuration) { @Sendable isSilence, _, frameCount, outputData in
            self.render(frameCount: Int(frameCount),
                        into: outputData)
            isSilence.pointee = ObjCBool(false)

            return noErr
        }
    }

    private func render(frameCount: Int,
                        into outputData: UnsafeMutablePointer<AudioBufferList>)
    {
        let buffers = UnsafeMutableAudioBufferListPointer(outputData)
        guard let output = buffers.first?.mData?.assumingMemoryBound(to: Float32.self) else { return }

        let pulsesPerSecond = self.pulsesPerSecond.load(ordering: .relaxed)
        let pitch = self.pitch.load(ordering: .relaxed)
        var tonePhase = self.tonePhase.load(ordering: .relaxed)
        var pulsePhase = self.pulsePhase.load(ordering: .relaxed)
        var envelope = self.envelope.load(ordering: .relaxed)

        let toneStep = pitch / Self.sampleRate
        let pulseStep = pulsesPerSecond / Self.sampleRate
        let rampStep = 1 / (rampSeconds * Self.sampleRate)
        let isContinuous = pulsesPerSecond == 0

        for frame in 0..<frameCount {
            let gateIsOpen = isContinuous || pulsePhase < dutyCycle
            envelope = gateIsOpen ? min(1, envelope + rampStep) : max(0, envelope - rampStep)

            output[frame] = Float32(Self.sample(waveform, at: tonePhase) * envelope * Self.amplitude)

            tonePhase += toneStep
            if tonePhase >= 1 {
                tonePhase -= 1
            }
            pulsePhase += pulseStep
            if pulsePhase >= 1 {
                pulsePhase -= 1
            }
        }

        self.tonePhase.store(tonePhase, ordering: .relaxed)
        self.pulsePhase.store(pulsePhase, ordering: .relaxed)
        self.envelope.store(envelope, ordering: .relaxed)
    }

    /// One cycle of the waveform, `phase` in 0..<1, output in -1...1.
    private static func sample(_ waveform: Waveform,
                               at phase: Double) -> Double
    {
        switch waveform {
        case .sine:
            return sin(2 * .pi * phase)
        case .triangle:
            return 1 - 4 * abs(phase - 0.5)
        }
    }
}
#endif
