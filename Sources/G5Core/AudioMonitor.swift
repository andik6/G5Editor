import Foundation
import CoreAudio
import AudioToolbox
import os

public struct AudioMonitorError: Error, LocalizedError {
    public let message: String
    init(_ m: String) { message = m }
    public var errorDescription: String? { message }
}

/// A Core Audio device as shown in the monitor's output picker.
public struct AudioDevice: Identifiable, Hashable, Sendable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
}

/// Small helpers around the Core Audio HAL property API.
public enum CoreAudioDevices {
    static func address(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func allIDs() -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func string(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String {
        var addr = address(sel)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let v = value else { return "" }
        return v.takeRetainedValue() as String
    }

    public static func channels(_ id: AudioDeviceID, input: Bool) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    public static func sampleRate(_ id: AudioDeviceID) -> Double {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate)
        return rate
    }

    static func device(_ id: AudioDeviceID) -> AudioDevice {
        AudioDevice(id: id, uid: string(id, kAudioDevicePropertyDeviceUID), name: string(id, kAudioObjectPropertyName))
    }

    /// True for the pedal's own USB audio ("ZOOM G Series"). Deliberately strict: the Zoom meetings app
    /// installs a virtual "ZoomAudioDevice" that must never be mistaken for the G5.
    static func isG5(_ name: String) -> Bool {
        name.uppercased().hasPrefix("ZOOM G")
    }

    /// Every audio device, in Core Audio's order (for diagnostics).
    public static func all() -> [(device: AudioDevice, inputs: Int, outputs: Int)] {
        allIDs().map { (device($0), channels($0, input: true), channels($0, input: false)) }
    }

    /// The G5's USB audio input ("ZOOM G Series").
    public static func zoomInput() -> AudioDevice? {
        allIDs().first { isG5(string($0, kAudioObjectPropertyName)) && channels($0, input: true) > 0 }.map(device)
    }

    /// Every device that can play sound, except the G5 itself and Zoom's virtual meeting device.
    public static func outputs() -> [AudioDevice] {
        allIDs().filter { channels($0, input: false) > 0 }.map(device)
            .filter { !isG5($0.name) && !$0.name.localizedCaseInsensitiveContains("ZoomAudioDevice") }
    }

    /// False once a device has been unplugged or has stopped working.
    public static func isAlive(_ id: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyDeviceIsAlive)
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &alive) == noErr && alive != 0
    }

    public static func defaultOutputID() -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    /// Changes a device's nominal sample rate (as Audio MIDI Setup does).
    public static func setSampleRate(_ id: AudioDeviceID, _ rate: Double) -> Bool {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var r = rate
        return AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float64>.size), &r) == noErr
    }

    static func setBufferSize(_ id: AudioDeviceID, _ frames: UInt32) {
        var addr = address(kAudioDevicePropertyBufferFrameSize)
        var f = frames
        AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &f)
    }

    static func bufferSize(_ id: AudioDeviceID) -> Int {
        var addr = address(kAudioDevicePropertyBufferFrameSize)
        var f: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &f)
        return Int(f)
    }

    /// Calls `handler` on the main queue whenever devices are plugged in or removed.
    public static func observeDeviceList(_ handler: @escaping () -> Void) {
        var addr = address(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { _, _ in handler() }
    }
}

/// Plays the G5's USB audio (guitar with effects) on another output device in real time.
///
/// Two independent HAL IOProcs are joined by a stereo ring buffer. The output side resamples with an
/// AudioConverter (the G5 runs at 44.1 kHz, most interfaces at 48 kHz) and absorbs clock drift by
/// re-priming on underrun and skipping ahead when the buffer grows too large.
public final class AudioMonitor {
    public struct Stats: Sendable {
        public var inputFrames = 0, outputFrames = 0, underruns = 0, skips = 0
        public var inputPeak: Float = 0, outputPeak: Float = 0
        public var latencyMs: Double = 0
    }

    public let input: AudioDevice
    public let output: AudioDevice
    public let inputRate: Double, outputRate: Double
    /// Linear gain, 0…2. Read on the audio thread; a torn read of a Float is harmless.
    public var gain: Float = 1

    private let capacity = 16384                  // ring size in stereo frames (power of two)
    private let ring: UnsafeMutablePointer<Float>
    private var writePos = 0, readPos = 0         // monotonic frame counters, guarded by `lock`
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var primed = false
    private var target = 0                         // ring fill (frames) the output aims to keep
    private let maxTarget = 4096

    private var converter: AudioConverterRef?
    private let convIn: UnsafeMutablePointer<Float>, convOut: UnsafeMutablePointer<Float>
    private let scratchFrames = 8192
    private var inProc: AudioDeviceIOProcID?, outProc: AudioDeviceIOProcID?
    private var stats = Stats()
    private var running = false

    public init(input: AudioDevice, output: AudioDevice, bufferFrames: UInt32 = 128) throws {
        self.input = input; self.output = output
        inputRate = CoreAudioDevices.sampleRate(input.id)
        outputRate = CoreAudioDevices.sampleRate(output.id)
        guard inputRate > 0, outputRate > 0 else { throw AudioMonitorError("Couldn't read the audio sample rates.") }
        ring = .allocate(capacity: capacity * 2); ring.initialize(repeating: 0, count: capacity * 2)
        convIn = .allocate(capacity: scratchFrames * 2); convIn.initialize(repeating: 0, count: scratchFrames * 2)
        convOut = .allocate(capacity: scratchFrames * 2); convOut.initialize(repeating: 0, count: scratchFrames * 2)
        lock = .allocate(capacity: 1); lock.initialize(to: os_unfair_lock())

        CoreAudioDevices.setBufferSize(input.id, bufferFrames)
        CoreAudioDevices.setBufferSize(output.id, bufferFrames)
        let inBuf = CoreAudioDevices.bufferSize(input.id), outBuf = CoreAudioDevices.bufferSize(output.id)
        target = inBuf + Int(Double(outBuf) * inputRate / outputRate) + 64

        func fmt(_ rate: Double) -> AudioStreamBasicDescription {
            AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                        mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                                        mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        }
        var inFmt = fmt(inputRate), outFmt = fmt(outputRate)
        guard AudioConverterNew(&inFmt, &outFmt, &converter) == noErr, let converter else {
            throw AudioMonitorError("Couldn't create the sample-rate converter.")
        }
        var quality = UInt32(kAudioConverterQuality_High)
        AudioConverterSetProperty(converter, kAudioConverterSampleRateConverterQuality, UInt32(MemoryLayout<UInt32>.size), &quality)
    }

    deinit {
        stop()
        if let converter { AudioConverterDispose(converter) }
        ring.deallocate(); convIn.deallocate(); convOut.deallocate(); lock.deallocate()
    }

    public func start() throws {
        guard !running else { return }
        var err = AudioDeviceCreateIOProcIDWithBlock(&inProc, input.id, nil) { [unowned self] _, inData, _, _, _ in
            self.capture(inData)
        }
        guard err == noErr else { throw AudioMonitorError("Couldn't open the G5 audio input (\(err)).") }
        err = AudioDeviceCreateIOProcIDWithBlock(&outProc, output.id, nil) { [unowned self] _, _, _, outData, _ in
            self.render(outData)
        }
        guard err == noErr else { stop(); throw AudioMonitorError("Couldn't open \(output.name) (\(err)).") }
        running = true
        guard AudioDeviceStart(input.id, inProc) == noErr, AudioDeviceStart(output.id, outProc) == noErr else {
            stop(); throw AudioMonitorError("Couldn't start audio on \(output.name).")
        }
    }

    public func stop() {
        if let p = inProc { AudioDeviceStop(input.id, p); AudioDeviceDestroyIOProcID(input.id, p); inProc = nil }
        if let p = outProc { AudioDeviceStop(output.id, p); AudioDeviceDestroyIOProcID(output.id, p); outProc = nil }
        running = false
    }

    /// Returns the counters since the last call (peaks reset, totals kept).
    public func takeStats() -> Stats {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        var s = stats
        s.latencyMs = Double(target) / inputRate * 1000
            + Double(CoreAudioDevices.bufferSize(input.id)) / inputRate * 1000
            + Double(CoreAudioDevices.bufferSize(output.id)) / outputRate * 1000
        stats.inputPeak = 0; stats.outputPeak = 0
        return s
    }

    // MARK: audio threads

    private func capture(_ list: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        // Locate the first two channels across the (possibly several) device streams, without allocating.
        var lp: UnsafeMutablePointer<Float>?, ls = 1, rp: UnsafeMutablePointer<Float>?, rs = 1
        var frames = 0
        for b in buffers where b.mData != nil && b.mNumberChannels > 0 {
            let n = Int(b.mNumberChannels)
            let p = b.mData!.assumingMemoryBound(to: Float.self)
            if lp == nil {
                frames = Int(b.mDataByteSize) / (4 * n)
                lp = p; ls = n
                if n > 1 { rp = p + 1; rs = n; break }
            } else { rp = p; rs = n; break }
        }
        guard frames > 0, let lp else { return }
        let r = rp ?? lp
        if rp == nil { rs = ls }
        let l = (lp, ls), rr = (r, rs)
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        var peak = stats.inputPeak
        for i in 0..<frames {
            let a = l.0[i * l.1], b = rr.0[i * rr.1]
            let k = (writePos & (capacity - 1)) * 2
            ring[k] = a; ring[k + 1] = b
            writePos += 1
            peak = max(peak, abs(a), abs(b))
        }
        if writePos - readPos > capacity { readPos = writePos - capacity }   // overrun: drop oldest
        stats.inputFrames += frames; stats.inputPeak = peak
    }

    /// Copies up to `frames` stereo frames from the ring into `dst`, padding with silence.
    fileprivate func pull(_ dst: UnsafeMutablePointer<Float>, frames: Int) {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        let avail = min(frames, writePos - readPos)
        for i in 0..<avail {
            let k = (readPos & (capacity - 1)) * 2
            dst[i * 2] = ring[k]; dst[i * 2 + 1] = ring[k + 1]
            readPos += 1
        }
        if avail < frames { (dst + avail * 2).update(repeating: 0, count: (frames - avail) * 2) }
    }

    private func render(_ list: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        var outFrames = 0
        for b in buffers where b.mNumberChannels > 0 { outFrames = Int(b.mDataByteSize) / (4 * Int(b.mNumberChannels)); break }
        outFrames = min(outFrames, scratchFrames)
        guard outFrames > 0, let converter else { return }

        // Decide whether there is enough audio buffered to play this cycle.
        let needIn = Int((Double(outFrames) * inputRate / outputRate).rounded(.up)) + 8
        var play = true
        os_unfair_lock_lock(lock)
        let fill = writePos - readPos
        if !primed {
            if fill >= target { primed = true } else { play = false }
        } else if fill < needIn {
            primed = false; play = false; stats.underruns += 1
            target = min(maxTarget, target + 64)            // underrun: keep a little more in reserve
        }
        if play && fill > target + needIn + 1024 {          // input clock ahead: skip back to target
            readPos = writePos - target; stats.skips += 1
        }
        os_unfair_lock_unlock(lock)

        var produced = 0
        if play {
            var packets = UInt32(outFrames)
            var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(outFrames * 8), mData: UnsafeMutableRawPointer(convOut)))
            let me = Unmanaged.passUnretained(self).toOpaque()
            if AudioConverterFillComplexBuffer(converter, monitorInputProc, me, &packets, &abl, nil) == noErr {
                produced = Int(packets)
            }
        }
        if produced < outFrames { (convOut + produced * 2).update(repeating: 0, count: (outFrames - produced) * 2) }

        // Write L/R into the device's first two channels, silence everywhere else.
        let g = gain
        var peak: Float = 0
        var channel = 0
        for b in buffers where b.mData != nil {
            let n = Int(b.mNumberChannels)
            let p = b.mData!.assumingMemoryBound(to: Float.self)
            let frames = min(outFrames, Int(b.mDataByteSize) / (4 * max(n, 1)))
            for c in 0..<n {
                let src = channel + c
                for i in 0..<frames {
                    let v = src < 2 ? convOut[i * 2 + src] * g : 0
                    p[i * n + c] = v
                    peak = max(peak, abs(v))
                }
            }
            channel += n
        }
        os_unfair_lock_lock(lock)
        stats.outputFrames += outFrames; stats.outputPeak = max(stats.outputPeak, peak)
        os_unfair_lock_unlock(lock)
    }

    fileprivate var scratchCapacity: Int { scratchFrames }
    fileprivate var converterInput: UnsafeMutablePointer<Float> { convIn }
}

/// Feeds the converter from the ring buffer (always supplies the requested amount, padding with silence).
private func monitorInputProc(_ conv: AudioConverterRef, _ ioPackets: UnsafeMutablePointer<UInt32>,
                              _ ioData: UnsafeMutablePointer<AudioBufferList>,
                              _ desc: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
                              _ user: UnsafeMutableRawPointer?) -> OSStatus {
    let m = Unmanaged<AudioMonitor>.fromOpaque(user!).takeUnretainedValue()
    let n = min(Int(ioPackets.pointee), m.scratchCapacity)
    m.pull(m.converterInput, frames: n)
    ioPackets.pointee = UInt32(n)
    ioData.pointee.mNumberBuffers = 1
    ioData.pointee.mBuffers = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(n * 8), mData: UnsafeMutableRawPointer(m.converterInput))
    return noErr
}
