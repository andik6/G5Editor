import CoreMIDI
import Foundation

public enum G5Error: Error, LocalizedError {
    case notFound, timeout(String), badReply(String)
    public var errorDescription: String? {
        switch self {
        case .notFound: return "The G5 isn't connected. Plug it in over USB and switch it on."
        case .timeout(let s): return "The pedal didn't answer (\(s))."
        case .badReply(let s): return "Unexpected reply from the pedal (\(s))."
        }
    }
}

/// Thin CoreMIDI wrapper: finds the "ZOOM G Series" port, sends SysEx, and
/// reassembles incoming SysEx (UMP type 3) into complete F0…F7 messages.
public final class MIDIConnection {
    private var client = MIDIClientRef()
    private var inPort = MIDIPortRef()
    private var outPort = MIDIPortRef()
    private var destination: MIDIEndpointRef = 0
    private var source: MIDIEndpointRef = 0
    private var partial: [UInt8] = []
    private var inbox: [[UInt8]] = []
    private let cond = NSCondition()
    public var onSetupChanged: (() -> Void)?
    public var onUnsolicited: (([UInt8]) -> Void)?

    public init() {
        MIDIClientCreateWithBlock("G5Editor" as CFString, &client) { [weak self] note in
            if note.pointee.messageID == .msgSetupChanged { self?.onSetupChanged?() }
        }
        MIDIInputPortCreateWithProtocol(client, "in" as CFString, ._1_0, &inPort) { [weak self] list, _ in
            self?.receive(list)
        }
        MIDIOutputPortCreate(client, "out" as CFString, &outPort)
    }

    private static func name(_ e: MIDIEndpointRef) -> String {
        var s: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(e, kMIDIPropertyDisplayName, &s)
        return (s?.takeRetainedValue() as String?) ?? ""
    }

    /// Connects to the first MIDI endpoint whose name contains "ZOOM".
    public func connect() throws {
        if source != 0 { MIDIPortDisconnectSource(inPort, source) }
        source = 0; destination = 0
        for i in 0..<MIDIGetNumberOfSources() where Self.name(MIDIGetSource(i)).uppercased().contains("ZOOM") {
            source = MIDIGetSource(i); break
        }
        for i in 0..<MIDIGetNumberOfDestinations() where Self.name(MIDIGetDestination(i)).uppercased().contains("ZOOM") {
            destination = MIDIGetDestination(i); break
        }
        guard source != 0, destination != 0 else { throw G5Error.notFound }
        MIDIPortConnectSource(inPort, source, nil)
    }

    public var isConnected: Bool { source != 0 && destination != 0 }

    private func receive(_ list: UnsafePointer<MIDIEventList>) {
        var done: [[UInt8]] = []
        for packet in list.unsafeSequence() {
            let w = withUnsafeBytes(of: packet.pointee.words) {
                Array($0.bindMemory(to: UInt32.self).prefix(Int(packet.pointee.wordCount)))
            }
            var i = 0
            while i < w.count {
                let mt = w[i] >> 28
                if mt == 3, i + 1 < w.count {
                    let status = (w[i] >> 20) & 0xF, n = Int((w[i] >> 16) & 0xF)
                    let b: [UInt8] = [UInt8((w[i] >> 8) & 0xFF), UInt8(w[i] & 0xFF),
                                      UInt8(w[i+1] >> 24), UInt8((w[i+1] >> 16) & 0xFF),
                                      UInt8((w[i+1] >> 8) & 0xFF), UInt8(w[i+1] & 0xFF)]
                    if status == 0 || status == 1 { partial = [0xF0] }
                    partial += b.prefix(min(n, 6))
                    if status == 0 || status == 3 { partial.append(0xF7); done.append(partial); partial = [] }
                    i += 2
                } else if mt == 2 {
                    // MIDI 1.0 channel voice (e.g. bank select / program change)
                    let st = UInt8((w[i] >> 16) & 0xFF), d1 = UInt8((w[i] >> 8) & 0x7F), d2 = UInt8(w[i] & 0x7F)
                    done.append((st & 0xF0) == 0xC0 || (st & 0xF0) == 0xD0 ? [st, d1] : [st, d1, d2])
                    i += 1
                } else {
                    i += (mt == 3 || mt == 4) ? 2 : (mt == 5 ? 4 : 1)
                }
            }
        }
        guard !done.isEmpty else { return }
        cond.lock(); inbox += done; cond.broadcast(); cond.unlock()
    }

    public func send(_ msg: [UInt8]) throws {
        guard destination != 0 else { throw G5Error.notFound }
        // Use a heap buffer big enough for long SysEx messages.
        let size = 1024 + msg.count
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { raw.deallocate() }
        let pl = raw.bindMemory(to: MIDIPacketList.self, capacity: 1)
        let pk = MIDIPacketListInit(pl)
        MIDIPacketListAdd(pl, size, pk, 0, msg.count, msg)
        MIDISend(outPort, destination, pl)
    }

    public func clearInbox() { cond.lock(); inbox.removeAll(); cond.unlock() }

    /// Waits for the first message matching `match`; other messages are dropped.
    public func wait(timeout: TimeInterval = 2, what: String, _ match: ([UInt8]) -> Bool) throws -> [UInt8] {
        let deadline = Date().addingTimeInterval(timeout)
        cond.lock(); defer { cond.unlock() }
        while true {
            while !inbox.isEmpty {
                let m = inbox.removeFirst()
                if match(m) { return m }
            }
            if !cond.wait(until: deadline) { throw G5Error.timeout(what) }
        }
    }

    /// Send then wait for a reply. Clears stale messages first.
    public func request(_ msg: [UInt8], timeout: TimeInterval = 2, what: String,
                        _ match: @escaping ([UInt8]) -> Bool) throws -> [UInt8] {
        clearInbox()
        try send(msg)
        return try wait(timeout: timeout, what: what, match)
    }
}
