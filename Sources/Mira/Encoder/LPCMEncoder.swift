import Foundation

// Anything that turns interleaved Float32 48 kHz stereo into timed TS audio frames.
protocol AudioEncoding: AnyObject, Sendable {
    var onEncoded: ((_ frame: Data, _ pts: Double) -> Void)? { get set }
    func encode(interleaved samples: [Float], pts: Double)
}

extension AACEncoder: AudioEncoding {}

// Wi-Fi Display LPCM: the one audio format every WFD sink must support. No encoder
// delay, ~1.5 Mbit/s. Each PES carries a 4-byte header and 6 "audio frames" of 80
// stereo samples (480 samples = 10 ms) of 16-bit big-endian PCM - the layout used
// by Android's Wi-Fi Display source.
final class LPCMEncoder: AudioEncoding, @unchecked Sendable {   // used only from MediaPipeline.audioQueue

    static let sampleRate = 48_000.0
    static let framesPerAudioFrame = 80
    static let audioFramesPerPES = 6
    static let framesPerPES = framesPerAudioFrame * audioFramesPerPES

    // sub_stream_id 0xA0, number_of_frame_header = 6, emphasis off,
    // quantization 16-bit (0) | sampling 48 kHz (2) | channels stereo (1)
    static let header: [UInt8] = [0xA0, UInt8(audioFramesPerPES), 0x00, (0 << 6) | (2 << 3) | 1]

    var onEncoded: ((_ frame: Data, _ pts: Double) -> Void)?

    private var fifo: [Int16] = []
    private var timelineStart: Double?
    private var framesQueued = 0
    private var framesOut = 0

    init() {
        Log.info("Audio", "LPCM 48 kHz 16-bit stereo")
    }

    func encode(interleaved samples: [Float], pts: Double) {
        let frames = samples.count / 2
        guard frames > 0 else { return }

        if let start = timelineStart {
            let drift = pts - (start + Double(framesQueued) / Self.sampleRate)
            if abs(drift) > 1.0 {
                reset(at: pts)
            } else if drift > 0.04 {
                let pad = Int(drift * Self.sampleRate)
                fifo.append(contentsOf: repeatElement(0, count: pad * 2))
                framesQueued += pad
            }
        } else {
            reset(at: pts)
        }

        fifo.reserveCapacity(fifo.count + samples.count)
        for s in samples {
            fifo.append(Int16(max(-1, min(1, s)) * 32767))
        }
        framesQueued += frames

        let samplesPerPES = Self.framesPerPES * 2
        while fifo.count >= samplesPerPES, let start = timelineStart {
            var out = Data(Self.header)
            out.reserveCapacity(4 + samplesPerPES * 2)
            for v in fifo[0..<samplesPerPES] {
                let u = UInt16(bitPattern: v)
                out.append(UInt8(u >> 8))           // big-endian
                out.append(UInt8(u & 0xFF))
            }
            fifo.removeFirst(samplesPerPES)
            let pts = start + Double(framesOut) / Self.sampleRate
            framesOut += Self.framesPerPES
            onEncoded?(out, pts)
        }
    }

    private func reset(at pts: Double) {
        fifo.removeAll(keepingCapacity: true)
        timelineStart = pts
        framesQueued = 0
        framesOut = 0
    }
}
