import AVFoundation
import AudioToolbox
import Foundation

actor SessionAudioArchive {
    private var handle: FileHandle?
    private var wavURL: URL?
    private var bytesWritten: UInt32 = 0

    func start(sessionID: UUID, preRoll: Data, directory: URL) throws {
        let url = directory.appendingPathComponent("\(sessionID.uuidString).wav")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        self.handle = handle
        wavURL = url
        bytesWritten = 0
        try handle.write(contentsOf: Self.wavHeader(dataByteCount: 0))
        if !preRoll.isEmpty {
            try handle.write(contentsOf: preRoll)
            bytesWritten += UInt32(clamping: preRoll.count)
        }
    }

    func append(_ data: Data) throws {
        guard let handle, !data.isEmpty else { return }
        try handle.write(contentsOf: data)
        bytesWritten += UInt32(clamping: data.count)
    }

    func finishAndCompress() async -> URL? {
        guard let handle, let wavURL else { return nil }
        do {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: Self.wavHeader(dataByteCount: bytesWritten))
            try handle.close()
        } catch {
            try? handle.close()
            self.handle = nil
            self.wavURL = nil
            return wavURL
        }
        self.handle = nil
        self.wavURL = nil

        do {
            let flacURL = wavURL.deletingPathExtension().appendingPathExtension("flac")
            try await Task.detached(priority: .utility) {
                try Self.transcodeToFLAC(wavURL: wavURL, flacURL: flacURL)
            }.value
            try? FileManager.default.removeItem(at: wavURL)
            return flacURL
        } catch {
            return wavURL
        }
    }

    func cancel() {
        try? handle?.close()
        if let wavURL { try? FileManager.default.removeItem(at: wavURL) }
        handle = nil
        wavURL = nil
        bytesWritten = 0
    }

    private static func wavHeader(dataByteCount: UInt32) -> Data {
        var data = Data()
        data.append("RIFF".data(using: .ascii)!)
        data.appendLittleEndian(UInt32(36) + dataByteCount)
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt32(16_000))
        data.appendLittleEndian(UInt32(32_000))
        data.appendLittleEndian(UInt16(2))
        data.appendLittleEndian(UInt16(16))
        data.append("data".data(using: .ascii)!)
        data.appendLittleEndian(dataByteCount)
        return data
    }

    private static func transcodeToFLAC(wavURL: URL, flacURL: URL) throws {
        let input = try AVAudioFile(forReading: wavURL)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatFLAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue
        ]
        let output = try AVAudioFile(
            forWriting: flacURL,
            settings: settings,
            commonFormat: input.processingFormat.commonFormat,
            interleaved: input.processingFormat.isInterleaved
        )
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 8_192) else {
            throw CocoaError(.fileWriteUnknown)
        }
        while input.framePosition < input.length {
            let remaining = AVAudioFrameCount(min(Int64(buffer.frameCapacity), input.length - input.framePosition))
            try input.read(into: buffer, frameCount: remaining)
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
        }
    }
}

enum ArchivedAudioReader {
    static func pcm16Chunks(from url: URL, framesPerChunk: AVAudioFrameCount = 1_920) throws -> [PCM16Chunk] {
        let input = try AVAudioFile(
            forReading: url,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        let format = input.processingFormat
        guard Int(format.sampleRate.rounded()) == 16_000,
              format.channelCount == 1 else {
            throw ASRProviderError.unavailable(
                "历史音频格式不兼容：需要 16 kHz 单声道，实际为 \(Int(format.sampleRate)) Hz / \(format.channelCount) 声道"
            )
        }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: max(1, framesPerChunk)
        ) else {
            throw ASRProviderError.unavailable("无法创建历史音频读取缓冲区")
        }

        var chunks: [PCM16Chunk] = []
        var sequence: Int64 = 0
        while input.framePosition < input.length {
            let remaining = AVAudioFrameCount(min(
                Int64(buffer.frameCapacity),
                input.length - input.framePosition
            ))
            try input.read(into: buffer, frameCount: remaining)
            guard buffer.frameLength > 0 else { break }
            let audioBuffer = buffer.audioBufferList.pointee.mBuffers
            guard let bytes = audioBuffer.mData else {
                throw ASRProviderError.unavailable("历史音频没有可读取的 PCM 数据")
            }
            sequence += 1
            chunks.append(PCM16Chunk(
                sequence: sequence,
                data: Data(bytes: bytes, count: Int(audioBuffer.mDataByteSize)),
                capturedAt: Date(),
                sampleRate: 16_000,
                channels: 1
            ))
        }
        return chunks
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
