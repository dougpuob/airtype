import AVFoundation
import AudioToolbox
import Foundation

final class AudioRecorder {
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
    private var recordingStartedAt: Date?
    private var firstBufferLogged = false
    private var firstVoiceLogged = false
    private var activeMicrophoneDeviceName = ""

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
        audioLock.unlock()

        if alreadyPrepared, sameMicrophone {
            return
        }
        if alreadyPrepared {
            stop()
        }

        audioLock.lock()
        preRollPCM = Data()
        pcm = Data()
        audioLock.unlock()

        Logger.shared.log("Audio recorder preparing: selected_device_name=\(normalizedDeviceName.isEmpty ? "default" : normalizedDeviceName)")

        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted {
                Logger.shared.log("Microphone permission was denied")
            }
        }

        let input = engine.inputNode
        applyPreferredInputDevice(microphoneDeviceName: normalizedDeviceName)
        let inputFormat = input.inputFormat(forBus: 0)
        sampleRate = outputSampleRate
        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: outputSampleRate,
            channels: 1,
            interleaved: true
        )

        guard let outputFormat else {
            Logger.shared.log("Could not create recording format")
            return
        }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            guard let converted = self.convert(buffer, from: inputFormat, to: outputFormat) else { return }
            let data = self.data(from: converted)
            if data.isEmpty {
                return
            }
            self.handleAudio(data)
        }

        do {
            try engine.start()
            audioLock.lock()
            prepared = true
            activeMicrophoneDeviceName = normalizedDeviceName
            audioLock.unlock()
            Logger.shared.log(
                "Microphone input warmed: input_sample_rate=\(Int(inputFormat.sampleRate)), "
                + "output_sample_rate=\(Int(outputSampleRate)), input_channels=\(inputFormat.channelCount), buffer_size=1024, pre_roll_seconds=\(self.preRollSeconds)"
            )
        } catch {
            Logger.shared.log("Could not start microphone input: \(error)")
        }
    }

    func start(microphoneDeviceName: String, preRollSeconds: Double, onLevel: @escaping (Double) -> Void) {
        prepare(microphoneDeviceName: microphoneDeviceName, preRollSeconds: preRollSeconds)
        audioLock.lock()
        self.onLevel = onLevel
        pcm = preRollPCM
        isRecording = true
        recordingStartedAt = Date()
        firstBufferLogged = false
        firstVoiceLogged = false
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
        onLevel = nil
        recordingStartedAt = nil
        pcm = Data()
        preRollPCM = Data()
        audioLock.unlock()
        Logger.shared.log("Audio recorder stopped and pre-roll cleared")
    }

    private func normalizeMicrophoneDeviceName(_ microphoneDeviceName: String) -> String {
        microphoneDeviceName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func selectedInputDevice(microphoneDeviceName: String) -> AVCaptureDevice? {
        guard !microphoneDeviceName.isEmpty else { return nil }
        let devices = Self.inputDevices()
        if let device = devices.first(where: { $0.localizedName == microphoneDeviceName }) {
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

    private func applyPreferredInputDevice(microphoneDeviceName: String) {
        guard let device = selectedInputDevice(microphoneDeviceName: microphoneDeviceName) else {
            Logger.shared.log("Using system default microphone input")
            return
        }
        guard var deviceID = audioDeviceID(for: device) else {
            Logger.shared.log("Could not resolve CoreAudio device for microphone: \(device.localizedName)")
            return
        }
        guard let audioUnit = engine.inputNode.audioUnit else {
            Logger.shared.log("Could not access input audio unit for microphone: \(device.localizedName)")
            return
        }

        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status == noErr {
            Logger.shared.log("Microphone input selected: selected_device_name=\(microphoneDeviceName), device_id=\(deviceID)")
        } else {
            Logger.shared.log("Could not select microphone input: selected_device_name=\(microphoneDeviceName), status=\(status)")
        }
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
        appendPreRoll(data)
        if isRecording {
            pcm.append(data)
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
        guard let pointer = buffer.int16ChannelData?[0] else { return Data() }
        return Data(bytes: pointer, count: Int(buffer.frameLength) * MemoryLayout<Int16>.size)
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
