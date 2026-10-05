#if os(macOS)
import CoreMIDI
import Foundation
import Observation
import OSLog

/// A Logic Pro key command triggered by a MIDI message that Logic Pro has learned.
enum LogicProCommand: CaseIterable, Sendable {
    case record
    case stop

    /// Undefined controllers on channel 16 avoid notes and common instrument
    /// controls, so a message Logic Pro hasn't learned yet stays inaudible.
    static let channel: UInt8 = 15

    var controller: UInt8 {
        switch self {
        case .record: 102
        case .stop: 103
        }
    }

    /// Logic Pro learns a lone full-value message as a fixed trigger. A quick
    /// press-and-release pair would instead teach it a range of values.
    var universalMIDIPacket: UInt32 {
        MIDI1UPControlChange(0, Self.channel, controller, 127)
    }
}

@MainActor
protocol LogicProCommandSending: AnyObject {
    /// Publishes the MIDI source early so Logic Pro is connected before the first command.
    func prepare() -> Bool
    func send(_ command: LogicProCommand) -> Bool
}

/// Sends commands from a virtual MIDI source, which Logic Pro receives with its other MIDI inputs.
@MainActor
final class MIDILogicProCommandSender: LogicProCommandSending {
    static let sourceName = "Singers Lyrics"

    private static let logger = Logger(
        subsystem: JSONLibraryStore.bundleIdentifier,
        category: "LogicPro"
    )
    /// `MIDIEventList.Builder` traps unless its storage, given in 32-bit words,
    /// holds at least one complete `MIDIEventList`.
    private static let eventListWordCount =
        (MemoryLayout<MIDIEventList>.size + MemoryLayout<UInt32>.size - 1) / MemoryLayout<UInt32>.size

    private let defaults: UserDefaults
    // The client and source last for the app session; CoreMIDI removes them when the app quits.
    private var client = MIDIClientRef()
    private var source = MIDIEndpointRef()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func prepare() -> Bool {
        guard source == 0 else { return true }
        if client == 0 {
            let status = MIDIClientCreateWithBlock(Self.sourceName as CFString, &client, nil)
            guard status == noErr else {
                client = 0
                Self.logger.error("Creating the MIDI client failed with status \(status)")
                return false
            }
        }

        var newSource = MIDIEndpointRef()
        let status = MIDISourceCreateWithProtocol(
            client,
            Self.sourceName as CFString,
            ._1_0,
            &newSource
        )
        guard status == noErr else {
            Self.logger.error("Creating the MIDI source failed with status \(status)")
            return false
        }
        restorePersistentIdentity(of: newSource)
        source = newSource
        return true
    }

    func send(_ command: LogicProCommand) -> Bool {
        guard prepare() else { return false }
        let events = MIDIEventList.Builder(inProtocol: ._1_0, wordSize: Self.eventListWordCount)
        guard events.append(timestamp: 0, words: [command.universalMIDIPacket]) != nil else {
            return false
        }
        let status = events.withUnsafePointer { MIDIReceivedEventList(source, $0) }
        guard status == noErr else {
            Self.logger.error("Sending a Logic Pro command failed with status \(status)")
            return false
        }
        return true
    }

    /// Logic Pro matches learned assignments to the source's unique ID, so reuse the
    /// ID from earlier launches. A rare collision keeps the newly assigned ID instead.
    private func restorePersistentIdentity(of source: MIDIEndpointRef) {
        if let savedID = defaults.object(forKey: PreferenceKey.logicProMIDISourceID) as? Int,
           let uniqueID = MIDIUniqueID(exactly: savedID) {
            _ = MIDIObjectSetIntegerProperty(source, kMIDIPropertyUniqueID, uniqueID)
        }
        var uniqueID = MIDIUniqueID()
        if MIDIObjectGetIntegerProperty(source, kMIDIPropertyUniqueID, &uniqueID) == noErr {
            defaults.set(Int(uniqueID), forKey: PreferenceKey.logicProMIDISourceID)
        }
    }
}

/// Keeps automated tests from publishing a MIDI source or reaching Logic Pro.
@MainActor
final class InertLogicProCommandSender: LogicProCommandSending {
    private let isAvailable: Bool
    private(set) var sentCommands: [LogicProCommand] = []

    init(isAvailable: Bool = true) {
        self.isAvailable = isAvailable
    }

    func prepare() -> Bool { isAvailable }

    func send(_ command: LogicProCommand) -> Bool {
        guard isAvailable else { return false }
        sentCommands.append(command)
        return true
    }
}

/// Records a Logic Pro take while the player's song plays.
///
/// A play action in the player starts the take; any pause ends it. Playback
/// started elsewhere, such as from the editor's timing controls, never records.
@MainActor
@Observable
final class LogicProRecordingModel {
    private let sender: any LogicProCommandSending
    private let defaults: UserDefaults

    private(set) var isArmed: Bool
    /// The song whose playback Logic Pro is recording, once Record has been sent.
    private(set) var recordingSongID: UUID?
    private(set) var isUnavailable = false

    var isRecording: Bool { recordingSongID != nil }

    init(sender: any LogicProCommandSending, defaults: UserDefaults = .standard) {
        self.sender = sender
        self.defaults = defaults
        isArmed = defaults.bool(forKey: PreferenceKey.recordsInLogicPro)
        // Logic Pro connects to a new source asynchronously and would miss a command
        // sent right after it appears, such as when recording is turned on mid-song.
        prepare()
    }

    func setArmed(_ armed: Bool) {
        guard armed != isArmed else { return }
        isArmed = armed
        defaults.set(armed, forKey: PreferenceKey.recordsInLogicPro)
        if armed {
            prepare()
        } else {
            stopRecording()
        }
    }

    func prepare() {
        isUnavailable = !sender.prepare()
    }

    /// Call after a play action in the player finishes, so a failed start never records.
    func startRecording(songID: UUID, isPlaying: Bool) {
        guard isArmed, isPlaying, recordingSongID != songID else { return }
        stopRecording()
        guard send(.record) else { return }
        recordingSongID = songID
    }

    /// Ends only a take started here: Stop moves an already stopped Logic Pro
    /// playhead to the project start.
    func stopRecording() {
        guard recordingSongID != nil else { return }
        recordingSongID = nil
        send(.stop)
    }

    /// Also sends a command directly while Logic Pro learns its assignment.
    @discardableResult
    func send(_ command: LogicProCommand) -> Bool {
        let sent = sender.send(command)
        isUnavailable = !sent
        return sent
    }
}
#endif
