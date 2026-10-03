import AVFoundation
import Foundation

final class PCMConverter {
    enum ConversionError: Error {
        case cannotCreateFormat
        case cannotCreateConverter
        case cannotCreateBuffer
        case conversionFailed(String)
        case missingChannelData
    }

    static let targetSampleRate: Double = 16_000
    static let targetChannels: AVAudioChannelCount = 1

    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    private let destinationFormat: AVAudioFormat = {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: false
        ) else {
            fatalError("Unable to create 16 kHz mono PCM format")
        }
        return format
    }()

    func convert(_ input: AVAudioPCMBuffer) throws -> Data {
        if sourceFormat != input.format || converter == nil {
            sourceFormat = input.format
            guard let newConverter = AVAudioConverter(from: input.format, to: destinationFormat) else {
                throw ConversionError.cannotCreateConverter
            }
            newConverter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            converter = newConverter
        }

        guard let converter else { throw ConversionError.cannotCreateConverter }
        let ratio = destinationFormat.sampleRate / input.format.sampleRate
        let estimatedFrames = max(1, Int(ceil(Double(input.frameLength) * ratio)) + 32)
        guard let output = AVAudioPCMBuffer(
            pcmFormat: destinationFormat,
            frameCapacity: AVAudioFrameCount(estimatedFrames)
        ) else {
            throw ConversionError.cannotCreateBuffer
        }

        var supplied = false
        var underlyingError: NSError?
        let status = converter.convert(to: output, error: &underlyingError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }

        if status == .error {
            throw ConversionError.conversionFailed(underlyingError?.localizedDescription ?? "Unknown AVAudioConverter error")
        }

        guard let channel = output.int16ChannelData?.pointee else {
            throw ConversionError.missingChannelData
        }
        return Data(bytes: channel, count: Int(output.frameLength) * MemoryLayout<Int16>.size)
    }
}

extension AVAudioPCMBuffer {
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else { return nil }
        copy.frameLength = frameLength

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return nil }

        for index in 0..<sourceBuffers.count {
            guard let source = sourceBuffers[index].mData,
                  let destination = destinationBuffers[index].mData else { return nil }
            let byteCount = Int(sourceBuffers[index].mDataByteSize)
            memcpy(destination, source, byteCount)
            destinationBuffers[index].mDataByteSize = sourceBuffers[index].mDataByteSize
        }
        return copy
    }
}
