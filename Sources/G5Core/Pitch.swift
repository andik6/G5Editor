import Foundation
import Accelerate
import CoreAudio
import os

/// YIN pitch detector (de Cheveigné & Kawahara, 2002) tuned for guitar.
public struct PitchDetector {
    public let sampleRate: Double
    public var minFreq = 60.0          // below B1 (7-string / drop tunings)
    public var maxFreq = 1400.0        // above the 24th fret of the high E string
    public var threshold: Float = 0.12

    public init(sampleRate: Double) { self.sampleRate = sampleRate }

    /// Samples needed for one estimate.
    public var windowSize: Int { pad + 2048 + maxLag }
    /// Leading samples discarded after filtering, so filter start-up transients don't bias the estimate.
    let pad = 1024
    var maxLag: Int { Int(sampleRate / minFreq) + 2 }
    var minLag: Int { max(2, Int(sampleRate / maxFreq)) }

    /// Returns the fundamental in Hz and a clarity value 0…1, or nil if there is no clear pitch.
    public func detect(_ input: [Float]) -> (freq: Double, clarity: Double)? {
        // Pass 1: rough estimate on a gently low-passed signal.
        guard let rough = yin(Array(lowPass(input, cutoff: 1600, stages: 2).dropFirst(pad))) else { return nil }
        // Pass 2: filter just above that fundamental so the (slightly sharp) overtones can't pull the reading.
        let cutoff = min(1600, rough.freq * 1.45)
        guard let fine = yin(Array(lowPass(input, cutoff: cutoff, stages: 3).dropFirst(pad))),
              abs(1200 * log2(fine.freq / rough.freq)) < 60 else { return rough }
        return (fine.freq, rough.clarity)
    }

    func yin(_ x: [Float]) -> (freq: Double, clarity: Double)? {
        let maxTau = maxLag, w = x.count - maxTau
        guard w >= 512 else { return nil }
        // Ignore silence (about -55 dBFS RMS).
        var ms: Float = 0
        x.withUnsafeBufferPointer { vDSP_measqv($0.baseAddress!, 1, &ms, vDSP_Length(w)) }
        guard ms > 3e-6 else { return nil }

        // Difference function d(τ) = Σ (x[j] - x[j+τ])², via energies and dot products.
        var d = [Float](repeating: 0, count: maxTau + 1)
        x.withUnsafeBufferPointer { p in
            let b = p.baseAddress!
            var e0: Float = 0
            vDSP_svesq(b, 1, &e0, vDSP_Length(w))
            var eTau = e0
            for tau in 1...maxTau {
                // energy of x[tau ..< tau+w], updated incrementally
                eTau += b[tau + w - 1] * b[tau + w - 1] - b[tau - 1] * b[tau - 1]
                var dot: Float = 0
                vDSP_dotpr(b, 1, b + tau, 1, &dot, vDSP_Length(w))
                d[tau] = max(0, e0 + eTau - 2 * dot)
            }
        }
        // Cumulative mean normalised difference.
        var cmnd = [Float](repeating: 1, count: maxTau + 1)
        var running: Float = 0
        for tau in 1...maxTau {
            running += d[tau]
            cmnd[tau] = running > 0 ? d[tau] * Float(tau) / running : 1
        }
        // First dip under the threshold, walked down to its local minimum.
        var tau = minLag
        var found = -1
        while tau < maxTau {
            if cmnd[tau] < threshold {
                while tau + 1 < maxTau && cmnd[tau + 1] < cmnd[tau] { tau += 1 }
                found = tau; break
            }
            tau += 1
        }
        if found < 0 {
            // No dip under the threshold: accept the global minimum only if it is reasonably clear.
            let slice = cmnd[minLag..<maxTau]
            guard let m = slice.min(), m < 0.3, let i = slice.firstIndex(of: m) else { return nil }
            found = i
        }
        // Parabolic interpolation for sub-sample accuracy.
        var refined = Double(found)
        if found > 1 && found < maxTau - 1 {
            let a = Double(cmnd[found - 1]), b = Double(cmnd[found]), c = Double(cmnd[found + 1])
            let den = a - 2 * b + c
            if abs(den) > 1e-12 { refined += 0.5 * (a - c) / den }
        }
        let f = sampleRate / refined
        guard f >= minFreq, f <= maxFreq else { return nil }
        return (f, Double(max(0, 1 - cmnd[found])))
    }

    /// Cascaded 2nd-order Butterworth low-passes. They tame the upper harmonics
    /// (which are slightly sharp on real strings, and strong after distortion) without touching the fundamental.
    func lowPass(_ x: [Float], cutoff fc: Double, stages: Int) -> [Float] {
        let q = 1 / 2.0.squareRoot()
        let w0 = 2 * Double.pi * fc / sampleRate, alpha = sin(w0) / (2 * q), c = cos(w0)
        let a0 = 1 + alpha
        let b0 = (1 - c) / 2 / a0, b1 = (1 - c) / a0, b2 = b0, a1 = -2 * c / a0, a2 = (1 - alpha) / a0
        var y = x
        for _ in 0..<stages {
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for i in 0..<y.count {
                let xi = Double(y[i])
                let yi = b0 * xi + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                x2 = x1; x1 = xi; y2 = y1; y1 = yi
                y[i] = Float(yi)
            }
        }
        return y
    }
}

/// A pitch expressed as the nearest equal-tempered note.
public struct NoteReading: Equatable, Sendable {
    public let freq: Double
    public let midi: Int
    public let cents: Double
    public static let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
    public var name: String { Self.names[((midi % 12) + 12) % 12] }
    public var octave: Int { midi / 12 - 1 }

    public init(freq: Double, a4: Double = 440) {
        self.freq = freq
        let n = 69 + 12 * log2(freq / a4)
        midi = Int(n.rounded())
        cents = (n - Double(midi)) * 100
    }
}

/// Captures the G5's USB audio (left channel) into a ring buffer so the tuner can read the latest samples.
public final class AudioInputTap {
    public let device: AudioDevice
    public let sampleRate: Double
    private let capacity = 1 << 15
    private let ring: UnsafeMutablePointer<Float>
    private var writePos = 0
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var proc: AudioDeviceIOProcID?

    public init(device: AudioDevice) {
        self.device = device
        sampleRate = CoreAudioDevices.sampleRate(device.id)
        ring = .allocate(capacity: capacity); ring.initialize(repeating: 0, count: capacity)
        lock = .allocate(capacity: 1); lock.initialize(to: os_unfair_lock())
    }

    deinit { stop(); ring.deallocate(); lock.deallocate() }

    public func start() throws {
        guard proc == nil else { return }
        let err = AudioDeviceCreateIOProcIDWithBlock(&proc, device.id, nil) { [unowned self] _, inData, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            guard let b = buffers.first, let data = b.mData, b.mNumberChannels > 0 else { return }
            let ch = Int(b.mNumberChannels), p = data.assumingMemoryBound(to: Float.self)
            let frames = Int(b.mDataByteSize) / (4 * ch)
            os_unfair_lock_lock(self.lock)
            for i in 0..<frames { self.ring[self.writePos & (self.capacity - 1)] = p[i * ch]; self.writePos += 1 }
            os_unfair_lock_unlock(self.lock)
        }
        guard err == noErr, let proc else { throw AudioMonitorError("Couldn't open the G5 audio input (\(err)).") }
        guard AudioDeviceStart(device.id, proc) == noErr else { stop(); throw AudioMonitorError("Couldn't start the G5 audio input.") }
    }

    public func stop() {
        if let p = proc { AudioDeviceStop(device.id, p); AudioDeviceDestroyIOProcID(device.id, p); proc = nil }
    }

    /// The most recent `count` samples (oldest first).
    public func latest(_ count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        os_unfair_lock_lock(lock)
        let start = writePos - count
        for i in 0..<count where start + i >= 0 { out[i] = ring[(start + i) & (capacity - 1)] }
        os_unfair_lock_unlock(lock)
        return out
    }
}
