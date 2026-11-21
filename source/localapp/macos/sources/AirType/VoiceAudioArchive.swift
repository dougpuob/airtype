import AudioToolbox
import Foundation

/// Writes one voice-input recording as an Ogg Opus (`.opus`) file.
///
/// Core Audio encodes Opus, but its Ogg writer rejects these packets (`pck?`).
/// The CAF packets are valid Opus, so this muxes them into an Ogg Opus stream (RFC 7845).
enum VoiceAudioArchive {
    static let sampleRate = 16_000
    static let transcriptPrefixLength = 10

    struct Failure: Error, CustomStringConvertible {
        var message: String
        var description: String { message }
    }

    /// `yyyy-MM-dd_HHmmss` plus up to the first 10 characters of `transcript`.
    static func fileName(date: Date, transcript: String) -> String {
        let stamp = fileNameStamp.string(from: date)
        let prefix = transcriptPrefix(transcript)
        let base = prefix.isEmpty ? stamp : "\(stamp)_\(prefix)"
        return base + ".opus"
    }

    /// Saves 16 kHz mono Int16 PCM. Returns the file URL.
    static func save(pcm: Data, transcript: String, directory: String, date: Date = Date()) throws -> URL {
        let frames = pcm.count / MemoryLayout<Int16>.size
        guard frames > 0 else {
            throw Failure(message: "recording was empty")
        }
        let expanded = (directory.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard !expanded.isEmpty else {
            throw Failure(message: "audio folder is empty")
        }
        let folder = URL(fileURLWithPath: expanded, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw Failure(message: "could not create \(folder.path): \(error.localizedDescription)")
        }

        let encoded = try encodeOpus(pcm: pcm, frames: frames)
        let destination = uniqueURL(in: folder, date: date, transcript: transcript)
        do {
            try encoded.write(to: destination, options: .atomic)
        } catch {
            throw Failure(message: "could not write \(destination.path): \(error.localizedDescription)")
        }
        return destination
    }

    // MARK: - Name

    private static let fileNameStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter
    }()

    /// First 10 characters, without characters that break a file name.
    static func transcriptPrefix(_ transcript: String) -> String {
        let flattened = transcript
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        var kept = ""
        kept.reserveCapacity(transcriptPrefixLength)
        for character in flattened {
            if kept.count >= transcriptPrefixLength { break }
            if character == "/" || character == ":" || character == "\\" { continue }
            if character.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) { continue }
            kept.append(character)
        }
        return kept.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func uniqueURL(in folder: URL, date: Date, transcript: String) -> URL {
        let name = fileName(date: date, transcript: transcript)
        let base = (name as NSString).deletingPathExtension
        var candidate = folder.appendingPathComponent(name)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path), suffix < 1000 {
            candidate = folder.appendingPathComponent("\(base)-\(suffix).opus")
            suffix += 1
        }
        return candidate
    }

    // MARK: - Encode

    /// 16 kHz Int16 mono PCM → Ogg Opus bytes. Core Audio resamples to 48 kHz for the encoder.
    private static func encodeOpus(pcm: Data, frames: Int) throws -> Data {
        var client = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var fileFormat = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 0,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let formatStatus = AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, nil, &formatSize, &fileFormat)
        guard formatStatus == noErr, fileFormat.mFramesPerPacket > 0 else {
            throw Failure(message: "Opus encoder is unavailable (\(statusText(formatStatus)))")
        }

        let cafURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("airtype-voice-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: cafURL) }

        var ext: ExtAudioFileRef?
        let createStatus = ExtAudioFileCreateWithURL(
            cafURL as CFURL,
            kAudioFileCAFType,
            &fileFormat,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &ext
        )
        guard createStatus == noErr, let ext else {
            throw Failure(message: "could not start Opus encoder (\(statusText(createStatus)))")
        }
        var disposed = false
        defer {
            if !disposed { ExtAudioFileDispose(ext) }
        }

        let clientSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let clientStatus = ExtAudioFileSetProperty(ext, kExtAudioFileProperty_ClientDataFormat, clientSize, &client)
        guard clientStatus == noErr else {
            throw Failure(message: "could not set recording format (\(statusText(clientStatus)))")
        }
        preferSpeechBitrate(on: ext)

        let writeStatus: OSStatus = pcm.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return kAudio_ParamError }
            let buffer = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(frames * 2),
                mData: UnsafeMutableRawPointer(mutating: base)
            )
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: buffer)
            return ExtAudioFileWrite(ext, UInt32(frames), &list)
        }
        guard writeStatus == noErr else {
            throw Failure(message: "Opus encode failed (\(statusText(writeStatus)))")
        }
        // Flush the CAF so packet reads see the encoder's priming and remainder.
        ExtAudioFileDispose(ext)
        disposed = true

        let packets = try readOpusPackets(from: cafURL, framesPerPacket: Int(fileFormat.mFramesPerPacket))
        return try oggOpus(packets)
    }

    /// 24 kbps is plenty for a single voice and keeps the files small. The default is used if this is refused.
    private static func preferSpeechBitrate(on ext: ExtAudioFileRef) {
        var converter: AudioConverterRef?
        var size = UInt32(MemoryLayout<AudioConverterRef>.size)
        guard ExtAudioFileGetProperty(ext, kExtAudioFileProperty_AudioConverter, &size, &converter) == noErr,
              let converter else { return }
        var bitrate: UInt32 = 24_000
        AudioConverterSetProperty(
            converter,
            kAudioConverterEncodeBitRate,
            UInt32(MemoryLayout<UInt32>.size),
            &bitrate
        )
    }

    private struct OpusPackets {
        var packets: [Data]
        var framesPerPacket: Int
        var primingFrames: Int
        var validFrames: Int
    }

    private static func readOpusPackets(from url: URL, framesPerPacket: Int) throws -> OpusPackets {
        var audioFile: AudioFileID?
        let openStatus = AudioFileOpenURL(url as CFURL, .readPermission, kAudioFileCAFType, &audioFile)
        guard openStatus == noErr, let audioFile else {
            throw Failure(message: "could not read encoded audio (\(statusText(openStatus)))")
        }
        defer { AudioFileClose(audioFile) }

        var packetCount: UInt64 = 0
        var countSize = UInt32(MemoryLayout<UInt64>.size)
        guard AudioFileGetProperty(audioFile, kAudioFilePropertyAudioDataPacketCount, &countSize, &packetCount) == noErr,
              packetCount > 0, packetCount < UInt64(UInt32.max) else {
            throw Failure(message: "encoded audio had no packets")
        }

        var maxPacketSize: UInt32 = 0
        var maxSize = UInt32(MemoryLayout<UInt32>.size)
        AudioFileGetProperty(audioFile, kAudioFilePropertyMaximumPacketSize, &maxSize, &maxPacketSize)
        if maxPacketSize == 0 { maxPacketSize = 4_000 }

        let count = Int(packetCount)
        var bytes = Data(count: Int(maxPacketSize) * count + 64)
        var descriptions = [AudioStreamPacketDescription](
            repeating: AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: 0),
            count: count
        )
        var numBytes = UInt32(bytes.count)
        var numPackets = UInt32(count)
        let readStatus: OSStatus = bytes.withUnsafeMutableBytes { raw in
            AudioFileReadPacketData(audioFile, false, &numBytes, &descriptions, 0, &numPackets, raw.baseAddress)
        }
        guard readStatus == noErr, numPackets > 0 else {
            throw Failure(message: "could not read Opus packets (\(statusText(readStatus)))")
        }

        var packetInfo = AudioFilePacketTableInfo(mNumberValidFrames: 0, mPrimingFrames: 0, mRemainderFrames: 0)
        var infoSize = UInt32(MemoryLayout<AudioFilePacketTableInfo>.size)
        let infoStatus = AudioFileGetProperty(audioFile, kAudioFilePropertyPacketTableInfo, &infoSize, &packetInfo)
        let priming = infoStatus == noErr ? Int(packetInfo.mPrimingFrames) : 312
        let valid = infoStatus == noErr && packetInfo.mNumberValidFrames > 0
            ? Int(packetInfo.mNumberValidFrames)
            : Int(numPackets) * framesPerPacket

        var packets: [Data] = []
        packets.reserveCapacity(Int(numPackets))
        for description in descriptions.prefix(Int(numPackets)) {
            let start = Int(description.mStartOffset)
            let size = Int(description.mDataByteSize)
            guard size > 0, start >= 0, start + size <= bytes.count else { continue }
            packets.append(bytes.subdata(in: start..<(start + size)))
        }
        guard !packets.isEmpty else {
            throw Failure(message: "encoded audio packets were empty")
        }
        return OpusPackets(
            packets: packets,
            framesPerPacket: max(1, framesPerPacket),
            primingFrames: max(0, priming),
            validFrames: max(0, valid)
        )
    }

    // MARK: - Ogg Opus

    private static func oggOpus(_ encoded: OpusPackets) throws -> Data {
        let serial = UInt32.random(in: 1...UInt32.max)
        var sequence: UInt32 = 0
        var output = Data()

        let head = opusHead(preSkip: encoded.primingFrames, inputSampleRate: sampleRate)
        output.append(oggPage(packets: [head], granule: 0, flags: 0x02, serial: serial, sequence: &sequence))
        output.append(oggPage(packets: [opusTags()], granule: 0, flags: 0, serial: serial, sequence: &sequence))

        var decodedFrames = 0
        var timed: [(data: Data, granule: UInt64)] = []
        timed.reserveCapacity(encoded.packets.count)
        let trimAt = encoded.primingFrames + encoded.validFrames
        for packet in encoded.packets {
            decodedFrames += encoded.framesPerPacket
            let granule = trimAt > 0 ? min(decodedFrames, trimAt) : decodedFrames
            timed.append((packet, UInt64(max(0, granule))))
        }
        if let last = timed.indices.last, trimAt > 0 {
            timed[last].granule = UInt64(trimAt)
        }

        var index = 0
        while index < timed.count {
            var payload: [Data] = []
            var segments = 0
            var granule: UInt64 = 0
            while index < timed.count {
                let lace = segmentCount(for: timed[index].data.count)
                if segments + lace > 255 { break }
                payload.append(timed[index].data)
                segments += lace
                granule = timed[index].granule
                index += 1
            }
            if payload.isEmpty {
                throw Failure(message: "Opus packet is too large to mux")
            }
            let flags: UInt8 = index == timed.count ? 0x04 : 0
            output.append(oggPage(packets: payload, granule: granule, flags: flags, serial: serial, sequence: &sequence))
        }
        return output
    }

    private static func opusHead(preSkip: Int, inputSampleRate: Int) -> Data {
        var data = Data("OpusHead".utf8)
        data.append(1) // version
        data.append(1) // mono
        appendLE(UInt16(clamping: preSkip), to: &data)
        appendLE(UInt32(clamping: inputSampleRate), to: &data)
        appendLE(UInt16(0), to: &data) // output gain
        data.append(0) // mapping family
        return data
    }

    private static func opusTags() -> Data {
        let vendor = Data("AirType".utf8)
        var data = Data("OpusTags".utf8)
        appendLE(UInt32(vendor.count), to: &data)
        data.append(vendor)
        appendLE(UInt32(0), to: &data)
        return data
    }

    private static func oggPage(packets: [Data], granule: UInt64, flags: UInt8, serial: UInt32, sequence: inout UInt32) -> Data {
        var lacing: [UInt8] = []
        var payload = Data()
        for packet in packets {
            lacing.append(contentsOf: lacingValues(for: packet.count))
            payload.append(packet)
        }
        var page = Data()
        page.append(contentsOf: [0x4f, 0x67, 0x67, 0x53]) // OggS
        page.append(0) // version
        page.append(flags)
        appendLE(granule, to: &page)
        appendLE(serial, to: &page)
        appendLE(sequence, to: &page)
        sequence += 1
        appendLE(UInt32(0), to: &page) // checksum, patched below
        page.append(UInt8(lacing.count))
        page.append(contentsOf: lacing)
        page.append(payload)
        let checksum = oggCRC(page)
        page.replaceSubrange(22..<26, with: withUnsafeBytes(of: checksum.littleEndian) { Data($0) })
        return page
    }

    private static func lacingValues(for length: Int) -> [UInt8] {
        guard length > 0 else { return [0] }
        var values: [UInt8] = []
        var remaining = length
        while remaining >= 255 {
            values.append(255)
            remaining -= 255
        }
        values.append(UInt8(remaining))
        return values
    }

    private static func segmentCount(for length: Int) -> Int {
        lacingValues(for: length).count
    }

    private static let oggCRCTable: [UInt32] = {
        (0..<256).map { index in
            var remainder = UInt32(index) << 24
            for _ in 0..<8 {
                if remainder & 0x8000_0000 != 0 {
                    remainder = (remainder << 1) ^ 0x04c1_1db7
                } else {
                    remainder <<= 1
                }
            }
            return remainder
        }
    }()

    private static func oggCRC(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0
        for byte in data {
            let index = Int(((crc >> 24) & 0xff) ^ UInt32(byte))
            crc = (crc << 8) ^ oggCRCTable[index]
        }
        return crc
    }

    private static func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private static func statusText(_ status: OSStatus) -> String {
        let value = UInt32(bitPattern: status)
        let bytes = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        let text = bytes.map { (32..<127).contains(Int($0)) ? String(UnicodeScalar($0)) : "" }.joined()
        if text.count == 4 { return "'\(text)'" }
        return String(status)
    }
}
