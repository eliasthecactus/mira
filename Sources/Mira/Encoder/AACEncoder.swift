import Foundation
import AudioToolbox

// PCM (interleaved Float32, 48 kHz stereo) → AAC-LC frames wrapped in ADTS, which is
// how AAC is carried in MPEG-TS (stream_type 0x0F). WFD's AAC mode bit 0 is exactly
// this format, and it's the only AAC mode sinks must support.
final class AACEncoder: @unchecked Sendable {   // used only from MediaPipeline.audioQueue

    static let sampleRate = 48_000.0
    static let channels: UInt32 = 2
    static let framesPerPacket = 1024
    static let primingFrames = 2112            // Apple AAC encoder delay

    // (ADTS frame, presentation time in host-clock seconds)
    var onEncoded: ((_ adts: Data, _ pts: Double) -> Void)?

    private var converter: AudioConverterRef?
    private var fifo: [Float] = []             // interleaved L R L R …
    private var timelineStart: Double?         // host time of the first frame fed
    private var framesQueued = 0               // frames ever appended to the fifo
    private var packetsOut = 0
    private let feed = UnsafeMutablePointer<Float>.allocate(capacity: framesPerPacket * 2)
    private var feedFramesAvailable = 0
    private var maxOutputPacketSize: UInt32 = 1536
    private static let noDataStatus: OSStatus = 0x6E6F6474  // 'nodt'

    init(bitrate: UInt32 = 128_000) throws {
        var input = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: Self.channels, mBitsPerChannel: 32, mReserved: 0)
        var output = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate, mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: AudioFormatFlags(MPEG4ObjectID.AAC_LC.rawValue),
            mBytesPerPacket: 0, mFramesPerPacket: UInt32(Self.framesPerPacket), mBytesPerFrame: 0,
            mChannelsPerFrame: Self.channels, mBitsPerChannel: 0, mReserved: 0)

        var conv: AudioConverterRef?
        let status = AudioConverterNew(&input, &output, &conv)
        guard status == noErr, let conv else { throw EncoderError.converterCreationFailed(status) }
        converter = conv

        var br = bitrate
        AudioConverterSetProperty(conv, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &br)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var maxSize: UInt32 = 0
        if AudioConverterGetProperty(conv, kAudioConverterPropertyMaximumOutputPacketSize, &size, &maxSize) == noErr, maxSize > 0 {
            maxOutputPacketSize = maxSize
        }
        Log.info("Audio", "AAC-LC encoder 48 kHz stereo \(bitrate / 1000) kbps")
    }

    deinit {
        if let converter { AudioConverterDispose(converter) }
        feed.deallocate()
    }

    // Appends interleaved stereo frames captured at host time `pts` (seconds).
    func encode(interleaved samples: [Float], pts: Double) {
        let frames = samples.count / 2
        guard frames > 0 else { return }

        if let start = timelineStart {
            let expected = start + Double(framesQueued) / Self.sampleRate
            let drift = pts - expected
            if drift > 1.0 || drift < -1.0 {
                Log.info("Audio", String(format: "Audio timeline jump %.2fs — resetting encoder", drift))
                reset(at: pts)
            } else if drift > 0.04 {
                // Capture gap (SCStream stops delivering during silence): pad with silence.
                let pad = Int(drift * Self.sampleRate)
                fifo.append(contentsOf: [Float](repeating: 0, count: pad * 2))
                framesQueued += pad
            }
        } else {
            reset(at: pts)
        }

        fifo.append(contentsOf: samples)
        framesQueued += frames
        drain()
    }

    private func reset(at pts: Double) {
        if let converter { AudioConverterReset(converter) }
        fifo.removeAll(keepingCapacity: true)
        timelineStart = pts
        framesQueued = 0
        packetsOut = 0
    }

    private func drain() {
        guard let converter, let start = timelineStart else { return }
        let outBuf = UnsafeMutableRawPointer.allocate(byteCount: Int(maxOutputPacketSize), alignment: 16)
        defer { outBuf.deallocate() }

        while fifo.count >= Self.framesPerPacket * 2 {
            fifo.withUnsafeBufferPointer { src in
                feed.update(from: src.baseAddress!, count: Self.framesPerPacket * 2)
            }
            fifo.removeFirst(Self.framesPerPacket * 2)
            feedFramesAvailable = Self.framesPerPacket

            // Pull output until this 1024-frame chunk is consumed.
            while true {
                var packets: UInt32 = 1
                var desc = AudioStreamPacketDescription()
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: Self.channels, mDataByteSize: maxOutputPacketSize, mData: outBuf))
                let status = AudioConverterFillComplexBuffer(
                    converter, { _, ioPackets, ioData, _, userData in
                        let enc = Unmanaged<AACEncoder>.fromOpaque(userData!).takeUnretainedValue()
                        return enc.provideInput(ioPackets, ioData)
                    },
                    Unmanaged.passUnretained(self).toOpaque(), &packets, &list, &desc)

                if packets > 0 {
                    let size = Int(list.mBuffers.mDataByteSize)
                    let index = packetsOut
                    packetsOut += 1
                    // The first packets only carry encoder priming; skip them so every
                    // emitted frame has a non-negative timestamp on our timeline.
                    if index * Self.framesPerPacket >= Self.primingFrames - Self.framesPerPacket {
                        var adts = Data(Self.adtsHeader(payloadLength: size))
                        adts.append(Data(bytes: outBuf, count: size))
                        let pts = start + Double(index * Self.framesPerPacket - Self.primingFrames) / Self.sampleRate
                        onEncoded?(adts, pts)
                    }
                }
                if status != noErr && status != Self.noDataStatus {
                    Log.warn("Audio", "AudioConverterFillComplexBuffer error \(status)")
                    return
                }
                if feedFramesAvailable == 0 && packets == 0 { break }
                if feedFramesAvailable == 0 && status == Self.noDataStatus { break }
            }
        }
    }

    private func provideInput(_ ioPackets: UnsafeMutablePointer<UInt32>,
                              _ ioData: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        guard feedFramesAvailable > 0 else {
            ioPackets.pointee = 0
            return Self.noDataStatus
        }
        ioPackets.pointee = UInt32(feedFramesAvailable)
        ioData.pointee.mNumberBuffers = 1
        ioData.pointee.mBuffers.mNumberChannels = Self.channels
        ioData.pointee.mBuffers.mDataByteSize = UInt32(feedFramesAvailable * 8)
        ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(feed)
        feedFramesAvailable = 0
        return noErr
    }

    // 7-byte ADTS header, no CRC: AAC-LC, 48 kHz (index 3), 2 channels.
    static func adtsHeader(payloadLength: Int) -> [UInt8] {
        let frameLength = payloadLength + 7
        let profile = 1          // AAC LC (object type 2) − 1
        let freqIndex = 3        // 48000 Hz
        let channelConfig = 2
        return [
            0xFF,
            0xF1,                                                       // MPEG-4, layer 0, no CRC
            UInt8((profile << 6) | (freqIndex << 2) | (channelConfig >> 2)),
            UInt8(((channelConfig & 0x3) << 6) | (frameLength >> 11)),
            UInt8((frameLength >> 3) & 0xFF),
            UInt8(((frameLength & 0x7) << 5) | 0x1F),
            0xFC,
        ]
    }

    enum EncoderError: Error {
        case converterCreationFailed(OSStatus)
    }
}
