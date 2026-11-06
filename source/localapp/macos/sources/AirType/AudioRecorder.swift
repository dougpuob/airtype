import AVFoundation
import AudioToolbox
import Foundation

final class AudioRecorder: @unchecked Sendable {
    private let outputSampleRate: Double = 16_000
    private let minimumSpeechRMSLevel = 0.025
    private var preRollSeconds: Double = 2.0
    private let audioLock = NSLock()
    private let engine = AVAudioEngine()
    private var pcm = Data()
    private var preRollPCM = Data()
    private var sampleRate: Double = 16_000
    private var prepared = false
    private var isRecording = false
    private var onLevel: ((Double) -> Void)?
    // localapp: raw 16 kHz Int16 PCM forwarded to the streaming recognizer while recording.
    private var onPCM: ((Data) -> Void)?
    private var recordingStartedAt: Date?
    private var firstBufferLogged = false
    private var firstVoiceLogged = false
    private var emptyConvertedBufferLogged = false
    private var activeMicrophoneDeviceName = ""
    private var lastAudioBufferAt: Date?
    private var preferredDeviceNameRemembered = ""
    /// Fired on main when default input or device list may have changed.
    var onHardwareChange: (() -> Void)?
    private var hardwareListenersInstalled = false

    static func inputDevices() -> [AVCaptureDevice] {
        let deviceTypes: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            deviceTypes = [.microphone, .externalUnknown]
        } else {
            deviceTypes = [.builtInMicrophone, .externalUnknown]
        }

        return AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    func prepare(microphoneDeviceName: String, preRollSeconds: Double) {
        let normalizedDeviceName = normalizeMicrophoneDeviceName(microphoneDeviceName)

        audioLock.lock()
        self.preRollSeconds = min(5.0, max(0.0, preRollSeconds))
        let alreadyPrepared = prepared
        let sameMicrophone = activeMicrophoneDeviceName == normalizedDeviceName
        let recentAudio = lastAudioBufferAt.map { Date().timeIntervalSince($0) < 2.0 } ?? false
        let engineAlive = engine.isRunning
        audioLock.unlock()

        // Reuse a healthy warm engine; if the tap went quiet, rebuild.
        if alreadyPrepared, sameMicrophone, engineAlive, recentAudio {
            return
        }
        if alreadyPrepared {
            hardResetEngine(clearPreRoll: true)
        }

        audioLock.lock()
        preRollPCM = Data()
        pcm = Data()
        preferredDeviceNameRemembered = normalizedDeviceName
        lastAudioBufferAt = nil
        audioLock.unlock()

        Logger.shared.log("Audio recorder preparing: selected_device_name=\(normalizedDeviceName.isEmpty ? "default" : normalizedDeviceName)")

        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted {
                Logger.shared.log("Microphone permission was denied")
            }
        }

        let outcome = activateInput(preferredDeviceName: normalizedDeviceName, allowDefaultCycle: true)
        if !outcome.ready {
            Logger.shared.log(
                "Microphone input not ready after activation: preferred=\(normalizedDeviceName.isEmpty ? "default" : normalizedDeviceName), "
                + "active=\(outcome.activeLabel), buffers=\(outcome.bufferCount)"
            )
        }
    }

    func start(
        microphoneDeviceName: String,
        preRollSeconds: Double,
        onLevel: @escaping (Double) -> Void,
        onPCM: ((Data) -> Void)? = nil
    ) {
        prepare(microphoneDeviceName: microphoneDeviceName, preRollSeconds: preRollSeconds)
        audioLock.lock()
        self.onLevel = onLevel
        self.onPCM = onPCM
        pcm = preRollPCM
        // Pre-roll goes to the recognizer first, under the lock, so ordering with live buffers is kept.
        if !preRollPCM.isEmpty {
            onPCM?(preRollPCM)
        }
        isRecording = true
        recordingStartedAt = Date()
        firstBufferLogged = false
        firstVoiceLogged = false
        emptyConvertedBufferLogged = false
        let preRollBytes = preRollPCM.count
        audioLock.unlock()
        Logger.shared.log(
            "Audio recorder started: selected_device_name=\(microphoneDeviceName.isEmpty ? "default" : microphoneDeviceName), pre_roll_bytes=\(preRollBytes)"
        )
    }

    func stop() {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioLock.lock()
        isRecording = false
        prepared = false
        activeMicrophoneDeviceName = ""
        lastAudioBufferAt = nil
        onLevel = nil
        onPCM = nil
        recordingStartedAt = nil
        pcm = Data()
        preRollPCM = Data()
        audioLock.unlock()
        Logger.shared.log("Audio recorder stopped and pre-roll cleared")
    }

    /// localapp: stop forwarding audio to the streaming recognizer (no WAV is built).
    func stopStreaming() {
        audioLock.lock()
        isRecording = false
        onLevel = nil
        onPCM = nil
        recordingStartedAt = nil
        let recordedBytes = pcm.count
        pcm = Data()
        audioLock.unlock()
        Logger.shared.log("Audio recorder streaming stopped: pcm_bytes=\(recordedBytes)")
    }

    func discardRecording(clearPreRoll: Bool) {
        audioLock.lock()
        isRecording = false
        onLevel = nil
        onPCM = nil
        recordingStartedAt = nil
        pcm = Data()
        if clearPreRoll {
            preRollPCM = Data()
        }
        audioLock.unlock()
        Logger.shared.log("Audio recorder discarded current recording")
    }

    private func normalizeMicrophoneDeviceName(_ microphoneDeviceName: String) -> String {
        microphoneDeviceName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func isCurrentDeviceAvailable() -> Bool {
        audioLock.lock()
        defer { audioLock.unlock() }

        guard !activeMicrophoneDeviceName.isEmpty else {
            // Using the system's default device is considered usable.
            return true
        }

        let devices = Self.inputDevices()
        return devices.contains { $0.localizedName == activeMicrophoneDeviceName }
    }

    func isPreparedForInput() -> Bool {
        audioLock.lock()
        defer { audioLock.unlock() }
        return prepared
    }

    func ensureHardwareListeners() {
        guard !hardwareListenersInstalled else { return }
        hardwareListenersInstalled = true
        let callback: AudioObjectPropertyListenerProc = { _, _, _, client in
            guard let client else { return noErr }
            let recorder = Unmanaged<AudioRecorder>.fromOpaque(client).takeUnretainedValue()
            DispatchQueue.main.async {
                recorder.onHardwareChange?()
            }
            return noErr
        }
        let client = Unmanaged.passUnretained(self).toOpaque()
        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListener(AudioObjectID(kAudioObjectSystemObject), &defaultAddress, callback, client)
        AudioObjectAddPropertyListener(AudioObjectID(kAudioObjectSystemObject), &devicesAddress, callback, client)
        Logger.shared.log("Microphone hardware change listeners installed")
    }

        private func selectedInputDevice(microphoneDeviceName: String) -> AVCaptureDevice? {
        guard !microphoneDeviceName.isEmpty else { return nil }
        let devices = Self.inputDevices()
        if let device = devices.first(where: { $0.localizedName == microphoneDeviceName }) {
            return device
        }
        if let device = devices.first(where: { $0.uniqueID == microphoneDeviceName }) {
            return device
        }

        if let order = Int(microphoneDeviceName), order > 0 {
            let index = order - 1
            if devices.indices.contains(index) {
                let device = devices[index]
                Logger.shared.log("Using legacy microphone order \(microphoneDeviceName) as device name fallback: \(device.localizedName)")
                return device
            }
        }

        Logger.shared.log("Selected microphone device name not found, using system default: \(microphoneDeviceName)")
        return nil
    }

    private struct ActivationOutcome {
        var ready: Bool
        var activeLabel: String
        var bufferCount: Int
    }

    /// Stop the graph completely so the next CurrentDevice / default route takes effect.
    private func hardResetEngine(clearPreRoll: Bool) {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        } else {
            engine.inputNode.removeTap(onBus: 0)
        }
        engine.reset()
        audioLock.lock()
        prepared = false
        activeMicrophoneDeviceName = ""
        lastAudioBufferAt = nil
        if clearPreRoll {
            preRollPCM = Data()
            pcm = Data()
        }
        audioLock.unlock()
    }

    /// Preferred empty → follow system default.
    /// Preferred equals current system default → do NOT set CurrentDevice (explicit set can silence BT HALs).
    /// Preferred other device → set CurrentDevice; on dead input, cycle via default once without writing config.
    private func activateInput(preferredDeviceName: String, allowDefaultCycle: Bool) -> ActivationOutcome {
        let preferredDevice = selectedInputDevice(microphoneDeviceName: preferredDeviceName)
        let defaultDeviceID = systemDefaultInputDeviceID()
        let preferredID = preferredDevice.flatMap { audioDeviceID(for: $0) }
        let preferredIsSystemDefault = preferredDeviceName.isEmpty
            || (preferredID != nil && preferredID == defaultDeviceID)

        if preferredDeviceName.isEmpty || preferredIsSystemDefault {
            if let preferredDevice, preferredIsSystemDefault, !preferredDeviceName.isEmpty {
                Logger.shared.log(
                    "Preferred microphone matches system default; using default route without CurrentDevice override: "
                    + "\(preferredDevice.localizedName) uid=\(preferredDevice.uniqueID) device_id=\(preferredID ?? 0)"
                )
            } else {
                Logger.shared.log("Using system default microphone input")
            }
            var outcome = startEngineGraph(activeDeviceName: preferredDeviceName, setCurrentDevice: nil)
            if !outcome.ready {
                Logger.shared.log("Default-route microphone not ready; resetting engine and retrying once")
                hardResetEngine(clearPreRoll: true)
                outcome = startEngineGraph(activeDeviceName: preferredDeviceName, setCurrentDevice: nil)
            }
            return outcome
        }

        guard let preferredDevice, let preferredID else {
            Logger.shared.log("Preferred microphone unavailable; using system default without changing saved preference")
            return startEngineGraph(activeDeviceName: "", setCurrentDevice: nil)
        }

        var first = startEngineGraph(activeDeviceName: preferredDeviceName, setCurrentDevice: preferredID)
        if first.ready {
            return first
        }

        guard allowDefaultCycle else { return first }

        Logger.shared.log(
            "Preferred microphone produced no audio buffers; cycling via system default then retrying: "
            + "\(preferredDevice.localizedName)"
        )
        hardResetEngine(clearPreRoll: true)
        _ = startEngineGraph(activeDeviceName: "", setCurrentDevice: nil)
        // Brief settle on default route (bounded; not continuous monitoring).
        waitForAudioBuffers(timeout: 0.45, minimumBuffers: 1)
        hardResetEngine(clearPreRoll: true)
        var second = startEngineGraph(activeDeviceName: preferredDeviceName, setCurrentDevice: preferredID)
        if second.ready {
            Logger.shared.log("Preferred microphone recovered after default-route cycle")
            return second
        }

        // Last resort: keep default route alive so recording works; do not overwrite preference.
        Logger.shared.log(
            "Preferred microphone still not delivering audio; temporary fallback to system default "
            + "(saved preference unchanged: \(preferredDeviceName))"
        )
        hardResetEngine(clearPreRoll: true)
        second = startEngineGraph(activeDeviceName: "", setCurrentDevice: nil)
        return second
    }

    private func startEngineGraph(activeDeviceName: String, setCurrentDevice deviceID: AudioDeviceID?) -> ActivationOutcome {
        let input = engine.inputNode
        if let deviceID {
            applyCurrentDevice(deviceID, label: activeDeviceName)
        }

        // Re-read format after any device change.
        let inputFormat = input.inputFormat(forBus: 0)
        sampleRate = outputSampleRate
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: outputSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            Logger.shared.log("Could not create recording format")
            return ActivationOutcome(ready: false, activeLabel: activeDeviceName.isEmpty ? "default" : activeDeviceName, bufferCount: 0)
        }

        if inputFormat.sampleRate <= 0 || inputFormat.channelCount == 0 {
            Logger.shared.log(
                "Microphone input format invalid before start: sample_rate=\(inputFormat.sampleRate), channels=\(inputFormat.channelCount)"
            )
        }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            guard let converted = self.convert(buffer, from: inputFormat, to: outputFormat) else { return }
            let data = self.data(from: converted)
            if data.isEmpty {
                self.logEmptyConvertedBufferOnce(converted)
                return
            }
            self.handleAudio(data)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            Logger.shared.log("Could not start microphone input: \(error)")
            input.removeTap(onBus: 0)
            return ActivationOutcome(ready: false, activeLabel: activeDeviceName.isEmpty ? "default" : activeDeviceName, bufferCount: 0)
        }

        let buffers = waitForAudioBuffers(timeout: 2.0, minimumBuffers: 1)
        let ready = buffers >= 1
        audioLock.lock()
        prepared = ready || engine.isRunning
        // Track the preferred name the caller asked for when using default-route-for-matching-preferred.
        activeMicrophoneDeviceName = activeDeviceName
        audioLock.unlock()

        Logger.shared.log(
            "Microphone input warmed: input_sample_rate=\(Int(inputFormat.sampleRate)), "
            + "output_sample_rate=\(Int(outputSampleRate)), input_channels=\(inputFormat.channelCount), "
            + "input_format=\(formatDescription(inputFormat)), output_format=\(formatDescription(outputFormat)), "
            + "buffer_size=1024, pre_roll_seconds=\(preRollSeconds), "
            + "ready=\(ready), startup_buffers=\(buffers), route=\(activeDeviceName.isEmpty ? "system_default" : "preferred")"
        )
        return ActivationOutcome(
            ready: ready,
            activeLabel: activeDeviceName.isEmpty ? "default" : activeDeviceName,
            bufferCount: buffers
        )
    }

    @discardableResult
    private func waitForAudioBuffers(timeout: TimeInterval, minimumBuffers: Int) -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        var seen = 0
        var lastCount = 0
        while Date() < deadline {
            audioLock.lock()
            let bytes = preRollPCM.count
            let stamp = lastAudioBufferAt
            audioLock.unlock()
            if bytes > lastCount {
                seen += 1
                lastCount = bytes
            }
            if seen >= minimumBuffers, stamp != nil {
                return seen
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        audioLock.lock()
        let bytes = preRollPCM.count
        audioLock.unlock()
        // Count rough buffer quanta from pre-roll growth (~2KB int16 chunks are typical).
        if seen == 0, bytes > 0 {
            seen = max(1, bytes / 2048)
        }
        return seen
    }

    private func applyCurrentDevice(_ deviceID: AudioDeviceID, label: String) {
        guard let audioUnit = engine.inputNode.audioUnit else {
            Logger.shared.log("Could not access input audio unit for microphone: \(label)")
            return
        }
        var id = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status == noErr {
            Logger.shared.log("Microphone input selected: selected_device_name=\(label), device_id=\(deviceID)")
        } else {
            Logger.shared.log("Could not select microphone input: selected_device_name=\(label), status=\(status)")
        }
    }

    private func systemDefaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private func audioDeviceID(for device: AVCaptureDevice) -> AudioDeviceID? {
        let uid = device.uniqueID as CFString
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let qualifierSize = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafePointer(to: uid) { uidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                qualifierSize,
                uidPointer,
                &size,
                &deviceID
            )
        }
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    func stopAndMakeWav() -> Data? {
        audioLock.lock()
        isRecording = false
        onLevel = nil
        let recordedPCM = pcm
        pcm = Data()
        audioLock.unlock()

        let minimumPcmBytes = Int(outputSampleRate) * MemoryLayout<Int16>.size
        guard recordedPCM.count > minimumPcmBytes else {
            Logger.shared.log("Recording too short: pcm_bytes=\(recordedPCM.count), sample_rate=\(Int(sampleRate))")
            return nil
        }

        let rmsLevel = level(from: recordedPCM)
        guard rmsLevel >= minimumSpeechRMSLevel else {
            Logger.shared.log(
                "Recording skipped: RMS too low, rms_level=\(String(format: "%.4f", rmsLevel)), "
                + "threshold=\(String(format: "%.4f", minimumSpeechRMSLevel)), pcm_bytes=\(recordedPCM.count)"
            )
            return nil
        }

        let wav = makeWav(pcm: recordedPCM, sampleRate: Int(sampleRate))
        Logger.shared.log(
            "WAV created: pcm_bytes=\(recordedPCM.count), wav_bytes=\(wav.count), "
            + "sample_rate=\(Int(sampleRate)), rms_level=\(String(format: "%.4f", rmsLevel))"
        )
        return wav
    }

    private func handleAudio(_ data: Data) {
        let currentLevel = level(from: data)
        var callback: ((Double) -> Void)?
        var shouldLogFirstBuffer = false
        var shouldLogFirstVoice = false
        var firstBufferDelayMs = 0
        var firstVoiceDelayMs = 0

        audioLock.lock()
        lastAudioBufferAt = Date()
        appendPreRoll(data)
        if isRecording {
            pcm.append(data)
            onPCM?(data)
            callback = onLevel
            if !firstBufferLogged {
                firstBufferLogged = true
                shouldLogFirstBuffer = true
                firstBufferDelayMs = elapsedRecordingMs()
            }
            if !firstVoiceLogged && currentLevel > 0.08 {
                firstVoiceLogged = true
                shouldLogFirstVoice = true
                firstVoiceDelayMs = elapsedRecordingMs()
            }
        }
        audioLock.unlock()

        if shouldLogFirstBuffer {
            Logger.shared.log("First recording audio buffer captured: elapsed_ms=\(firstBufferDelayMs), bytes=\(data.count)")
        }
        if shouldLogFirstVoice {
            Logger.shared.log("First voice-like audio level captured: elapsed_ms=\(firstVoiceDelayMs), level=\(String(format: "%.3f", currentLevel))")
        }
        callback?(currentLevel)
    }

    private func appendPreRoll(_ data: Data) {
        preRollPCM.append(data)
        let limit = Int(outputSampleRate * preRollSeconds) * MemoryLayout<Int16>.size
        if preRollPCM.count > limit {
            preRollPCM.removeFirst(preRollPCM.count - limit)
        }
    }

    private func elapsedRecordingMs() -> Int {
        guard let recordingStartedAt else { return 0 }
        return Int(Date().timeIntervalSince(recordingStartedAt) * 1000)
    }

    private func convert(_ buffer: AVAudioPCMBuffer, from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard inputFormat != outputFormat else { return buffer }
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * outputFormat.sampleRate / inputFormat.sampleRate) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        var error: NSError?
        var used = false
        converter.convert(to: output, error: &error) { _, status in
            if used {
                status.pointee = .noDataNow
                return nil
            }
            used = true
            status.pointee = .haveData
            return buffer
        }
        if let error {
            Logger.shared.log("Audio conversion failed: \(error)")
            return nil
        }
        return output
    }

    private func data(from buffer: AVAudioPCMBuffer) -> Data {
        let byteCount = Int(buffer.frameLength) * Int(buffer.format.channelCount) * MemoryLayout<Int16>.size
        if let pointer = buffer.int16ChannelData?[0], byteCount > 0 {
            return Data(bytes: pointer, count: byteCount)
        }

        let audioBuffer = buffer.audioBufferList.pointee.mBuffers
        guard let data = audioBuffer.mData, audioBuffer.mDataByteSize > 0 else {
            return Data()
        }
        return Data(bytes: data, count: Int(audioBuffer.mDataByteSize))
    }

    private func logEmptyConvertedBufferOnce(_ buffer: AVAudioPCMBuffer) {
        audioLock.lock()
        let shouldLog = !emptyConvertedBufferLogged
        if shouldLog {
            emptyConvertedBufferLogged = true
        }
        audioLock.unlock()

        guard shouldLog else { return }
        let audioBuffer = buffer.audioBufferList.pointee.mBuffers
        Logger.shared.log(
            "Audio conversion produced empty data: frame_length=\(buffer.frameLength), "
            + "format=\(formatDescription(buffer.format)), "
            + "has_int16_channel_data=\(buffer.int16ChannelData != nil), "
            + "audio_buffer_bytes=\(audioBuffer.mDataByteSize)"
        )
    }

    private func formatDescription(_ format: AVAudioFormat) -> String {
        let commonFormat: String
        switch format.commonFormat {
        case .pcmFormatFloat32:
            commonFormat = "float32"
        case .pcmFormatFloat64:
            commonFormat = "float64"
        case .pcmFormatInt16:
            commonFormat = "int16"
        case .pcmFormatInt32:
            commonFormat = "int32"
        case .otherFormat:
            commonFormat = "other"
        @unknown default:
            commonFormat = "unknown"
        }
        return "\(commonFormat)/\(Int(format.sampleRate))Hz/\(format.channelCount)ch/interleaved=\(format.isInterleaved)"
    }

    private func level(from data: Data) -> Double {
        if data.isEmpty { return 0.02 }
        let count = data.count / MemoryLayout<Int16>.size
        let sum = data.withUnsafeBytes { rawBuffer -> Double in
            let samples = rawBuffer.bindMemory(to: Int16.self)
            return samples.reduce(0.0) { partial, sample in
                let value = Double(sample)
                return partial + value * value
            }
        }
        let rms = sqrt(sum / Double(max(1, count)))
        return min(1.0, rms / 32768.0 * 8.0)
    }

    private func makeWav(pcm: Data, sampleRate: Int) -> Data {
        var data = Data()
        let byteRate = sampleRate * 2
        let blockAlign: UInt16 = 2
        let bitsPerSample: UInt16 = 16
        let chunkSize = UInt32(36 + pcm.count)
        let subchunk2Size = UInt32(pcm.count)

        data.appendString("RIFF")
        data.appendLittleEndian(chunkSize)
        data.appendString("WAVE")
        data.appendString("fmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(UInt32(byteRate))
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(bitsPerSample)
        data.appendString("data")
        data.appendLittleEndian(subchunk2Size)
        data.append(pcm)
        return data
    }
}
