import Accelerate
import CoreAudio
import Foundation

/// Takes over the audio of ONE process and lets us scale its volume.
///
/// How it works (macOS 14.4+ Core Audio process taps):
///  1. Create a process tap (`AudioHardwareCreateProcessTap`) with
///     `.mutedWhenTapped` — the app's direct output is silenced while we tap it.
///  2. Create a private aggregate device that contains the current default
///     output device plus the tap.
///  3. Run an IO proc on the aggregate: tap audio arrives as input, we multiply
///     samples by `gain` and write them to the real output.
///
/// Destroying the tap automatically un-mutes the app's original audio path.
final class ProcessTap {

    let processObjectID: AudioObjectID
    private(set) var isActive = false

    private var tapID: AudioObjectID = .unknown
    private var aggregateID: AudioObjectID = .unknown
    private var ioProcID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "soundknobs.tap.io", qos: .userInitiated)

    /// Gain is read on the realtime IO thread; a single aligned Float32
    /// read/write is atomic on arm64/x86_64, so a plain pointer is fine here.
    private let gainPointer: UnsafeMutablePointer<Float>

    var gain: Float {
        get { gainPointer.pointee }
        set { gainPointer.pointee = min(max(newValue, 0), 1) }
    }

    init(processObjectID: AudioObjectID, initialGain: Float) {
        self.processObjectID = processObjectID
        gainPointer = .allocate(capacity: 1)
        gainPointer.initialize(to: min(max(initialGain, 0), 1))
    }

    deinit {
        invalidate()
        gainPointer.deallocate()
    }

    // MARK: - Activation

    func activate() throws {
        guard !isActive else { return }

        // 1. The tap. This is the call that requires the
        //    "System Audio Recording" privacy permission.
        let description = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        description.name = "SoundKnobs-\(processObjectID)"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped

        var newTapID = AudioObjectID.unknown
        try check(
            AudioHardwareCreateProcessTap(description, &newTapID),
            "Create process tap (is System Audio Recording permission granted?)"
        )
        tapID = newTapID

        do {
            // 2. Aggregate device: default output + our tap.
            let outputDevice = try readPOD(
                .system, kAudioHardwarePropertyDefaultOutputDevice, AudioDeviceID(0)
            )
            let outputUID = try readString(outputDevice, kAudioDevicePropertyDeviceUID)

            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "SoundKnobs Mixer \(processObjectID)",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [
                    [kAudioSubDeviceUIDKey: outputUID]
                ],
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapDriftCompensationKey: true,
                        kAudioSubTapUIDKey: description.uuid.uuidString,
                    ]
                ],
            ]

            var newAggregateID = AudioObjectID.unknown
            try check(
                AudioHardwareCreateAggregateDevice(
                    aggregateDescription as CFDictionary, &newAggregateID
                ),
                "Create aggregate device"
            )
            aggregateID = newAggregateID

            // 3. IO proc: tap input -> gain -> hardware output.
            let gp = gainPointer
            try check(
                AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue) {
                    _, inInputData, _, outOutputData, _ in

                    let input = UnsafeMutableAudioBufferListPointer(
                        UnsafeMutablePointer(mutating: inInputData)
                    )
                    let output = UnsafeMutableAudioBufferListPointer(outOutputData)
                    var g = gp.pointee

                    for i in 0..<output.count {
                        let outBuffer = output[i]
                        guard let outData = outBuffer.mData else { continue }

                        guard i < input.count, let inData = input[i].mData else {
                            memset(outData, 0, Int(outBuffer.mDataByteSize))
                            continue
                        }

                        let bytes = min(outBuffer.mDataByteSize, input[i].mDataByteSize)
                        let sampleCount = vDSP_Length(bytes / UInt32(MemoryLayout<Float>.size))
                        vDSP_vsmul(
                            inData.assumingMemoryBound(to: Float.self), 1,
                            &g,
                            outData.assumingMemoryBound(to: Float.self), 1,
                            sampleCount
                        )
                        if outBuffer.mDataByteSize > bytes {
                            memset(
                                outData.advanced(by: Int(bytes)), 0,
                                Int(outBuffer.mDataByteSize - bytes)
                            )
                        }
                    }
                },
                "Create IO proc"
            )

            try check(AudioDeviceStart(aggregateID, ioProcID), "Start aggregate device")
            isActive = true
        } catch {
            // Never leave the process muted with no audio path.
            invalidate()
            throw error
        }
    }

    // MARK: - Teardown

    func invalidate() {
        if let ioProcID, aggregateID != .unknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil

        if aggregateID != .unknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = .unknown
        }
        if tapID != .unknown {
            AudioHardwareDestroyProcessTap(tapID) // un-mutes the original app audio
            tapID = .unknown
        }
        isActive = false
    }
}
