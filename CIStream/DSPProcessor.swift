import AVFoundation
import Accelerate

final class DSPProcessor {

    struct Parameters: Sendable {
        var suppressionStrength: Float = 0.0
        var sceDepth: Float = 0.0      // spectral contrast enhancement
        var trebleBoost: Float = 0.0   // high-frequency shelf above 1 kHz
    }

    nonisolated(unsafe) var parameters = Parameters()

    // MARK: – Geometry
    private let n         = 1024    // FFT size
    private let hop       = 256     // must match tap bufferSize in AudioEngine
    private let h         = 512     // n/2
    private let log2n     : vDSP_Length = 10
    private let noiseTarget = 35    // frames before suppression activates (~200 ms)

    // MARK: – Audio-thread state (only touched inside nonisolated func process)
    nonisolated(unsafe) private var fftSetup  : FFTSetup?
    nonisolated(unsafe) private var window    = [Float](repeating: 0, count: 1024)
    nonisolated(unsafe) private var inBuf     = [Float](repeating: 0, count: 1024)
    nonisolated(unsafe) private var outRing   = [Float](repeating: 0, count: 1024)
    nonisolated(unsafe) private var workReal  = [Float](repeating: 0, count:  512)
    nonisolated(unsafe) private var workImag  = [Float](repeating: 0, count:  512)
    nonisolated(unsafe) private var windowed  = [Float](repeating: 0, count: 1024)
    nonisolated(unsafe) private var power     = [Float](repeating: 0, count:  512)
    nonisolated(unsafe) private var ifftBuf   = [Float](repeating: 0, count: 1024)
    nonisolated(unsafe) private var noisePow    = [Float](repeating: 1e-10, count: 512)
    nonisolated(unsafe) private var noiseAcc    = [Float](repeating: 0,     count: 512)
    nonisolated(unsafe) private var noiseFrames = 0
    nonisolated(unsafe) private var gainSmooth  = [Float](repeating: 1,    count: 512)

    init() {
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
    }

    deinit {
        if let s = fftSetup { vDSP_destroy_fftsetup(s) }
    }

    // Called on main thread when scene changes or user taps Reset
    func resetNoiseEstimate() {
        noiseFrames = 0
        noiseAcc    = [Float](repeating: 0,     count: h)
        noisePow    = [Float](repeating: 1e-10, count: h)
    }

    // MARK: – Main DSP entry point (called on audio thread)

    nonisolated func process(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        let strength = parameters.suppressionStrength
        guard strength > 0.01,
              let src   = input.floatChannelData?[0],
              let setup = fftSetup else { return input }

        let frames = Int(input.frameLength)

        guard let out = AVAudioPCMBuffer(pcmFormat: input.format,
                                         frameCapacity: input.frameCapacity),
              let dst = out.floatChannelData?[0] else { return input }
        out.frameLength = input.frameLength

        // Undersized buffer — copy through
        guard frames >= hop else {
            memcpy(dst, src, frames * MemoryLayout<Float>.stride)
            return out
        }

        var srcOff = 0
        var dstOff = 0

        while srcOff + hop <= frames {

            // 1. Slide analysis window: drop oldest hop, append new hop ───────
            inBuf.withUnsafeMutableBufferPointer { buf in
                let base = buf.baseAddress!
                memmove(base, base + hop, (n - hop) * MemoryLayout<Float>.stride)
                memcpy(base + (n - hop), src + srcOff, hop * MemoryLayout<Float>.stride)
            }
            srcOff += hop

            // 2. Hann window ──────────────────────────────────────────────────
            vDSP_vmul(inBuf, 1, window, 1, &windowed, 1, vDSP_Length(n))

            // 3. Forward real FFT → workReal / workImag ───────────────────────
            runFFT(setup: setup, isForward: true, io: &windowed)

            // 4. Power per bin ─────────────────────────────────────────────────
            workReal.withUnsafeMutableBufferPointer { rBuf in
                workImag.withUnsafeMutableBufferPointer { iBuf in
                    var split = DSPSplitComplex(realp: rBuf.baseAddress!,
                                               imagp: iBuf.baseAddress!)
                    vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(h))
                }
            }

            // 5. Noise estimation (first ~200 ms, then fixed) ─────────────────
            if noiseFrames < noiseTarget {
                vDSP_vadd(noiseAcc, 1, power, 1, &noiseAcc, 1, vDSP_Length(h))
                noiseFrames += 1
                if noiseFrames == noiseTarget {
                    var invN = Float(1) / Float(noiseTarget)
                    vDSP_vsmul(noiseAcc, 1, &invN, &noisePow, 1, vDSP_Length(h))
                }
                // During calibration: fall through with gain = 1 (transparent)
            } else {
                // 6. Wiener gain with temporal smoothing (eliminates musical noise)
                // G(k) = max(1 - α·noise/signal, floor), blended with previous frame
                let smoothing: Float = 0.85   // IIR: high = smoother, less artifact
                let floor:     Float = 0.20   // minimum gain per bin (20%)
                for k in 0..<h {
                    let raw = max(1.0 - strength * noisePow[k] / max(power[k], 1e-10), floor)
                    let g   = smoothing * gainSmooth[k] + (1.0 - smoothing) * raw
                    gainSmooth[k] = g
                    workReal[k] *= g
                    workImag[k] *= g
                }
            }

            // 6b. Spectral Contrast Enhancement ───────────────────────────────
            // Raises spectral peaks (speech formants) and lowers valleys (noise).
            // Uses original frame power so gains are relative to pre-suppression shape.
            let sce = parameters.sceDepth
            if sce > 0.01 {
                var meanPow: Float = 0
                vDSP_meanv(power, 1, &meanPow, vDSP_Length(h))
                meanPow = max(meanPow, 1e-10)
                for k in 0..<h {
                    let g = powf(max(power[k], 1e-10) / meanPow, sce * 0.4)
                    workReal[k] *= g
                    workImag[k] *= g
                }
            }

            // 6c. High-frequency emphasis (treble shelf above 1 kHz) ───────────
            // Boosts consonant energy: /s/, /f/, /t/ — the sounds CI users lose
            // first due to basal electrode coverage limits.
            let treble = parameters.trebleBoost
            if treble > 0.01 {
                let sr      = Float(input.format.sampleRate)
                let cutoff  = max(1, Int(1000.0 * Float(n) / sr))   // bin ≈ 1 kHz
                let maxBoost = powf(10.0, treble * 8.0 / 20.0)      // 0 → +8 dB
                for k in cutoff..<h {
                    let blend = min(Float(k - cutoff) / Float(cutoff), 1.0)
                    let g = 1.0 + (maxBoost - 1.0) * blend
                    workReal[k] *= g
                    workImag[k] *= g
                }
            }

            // 7. Inverse FFT → ifftBuf ────────────────────────────────────────
            runFFT(setup: setup, isForward: false, io: &ifftBuf)

            // Scale: vDSP round-trip = N, Hann-75%-OLA normalisation = 2.0
            var scale: Float = 1.0 / Float(n * 2)
            vDSP_vsmul(ifftBuf, 1, &scale, &ifftBuf, 1, vDSP_Length(n))

            // 8. Overlap-add ──────────────────────────────────────────────────
            vDSP_vadd(outRing, 1, ifftBuf, 1, &outRing, 1, vDSP_Length(n))

            // 9. Write hop samples to output ──────────────────────────────────
            outRing.withUnsafeBufferPointer { buf in
                _ = memcpy(dst + dstOff, buf.baseAddress!, hop * MemoryLayout<Float>.stride)
            }
            dstOff += hop

            // 10. Advance outRing ─────────────────────────────────────────────
            outRing.withUnsafeMutableBufferPointer { buf in
                let base = buf.baseAddress!
                memmove(base, base + hop, (n - hop) * MemoryLayout<Float>.stride)
                memset(base + (n - hop), 0, hop * MemoryLayout<Float>.stride)
            }
        }

        return out
    }

    // MARK: – FFT helper
    // isForward=true:  packs io[] → split via ctoz, runs forward fft_zrip.
    // isForward=false: runs inverse fft_zrip, unpacks split → io[] via ztoc.
    private nonisolated func runFFT(setup: FFTSetup,
                                    isForward: Bool,
                                    io: inout [Float]) {
        let dir: FFTDirection = isForward ? FFTDirection(FFT_FORWARD) : FFTDirection(FFT_INVERSE)
        workReal.withUnsafeMutableBufferPointer { rBuf in
            workImag.withUnsafeMutableBufferPointer { iBuf in
                var split = DSPSplitComplex(realp: rBuf.baseAddress!,
                                           imagp: iBuf.baseAddress!)
                if isForward {
                    io.withUnsafeMutableBufferPointer { sBuf in
                        sBuf.baseAddress!
                            .withMemoryRebound(to: DSPComplex.self, capacity: h) { cBuf in
                                vDSP_ctoz(cBuf, 2, &split, 1, vDSP_Length(h))
                            }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, dir)
                } else {
                    vDSP_fft_zrip(setup, &split, 1, log2n, dir)
                    io.withUnsafeMutableBufferPointer { sBuf in
                        sBuf.baseAddress!
                            .withMemoryRebound(to: DSPComplex.self, capacity: h) { cBuf in
                                vDSP_ztoc(&split, 1, cBuf, 2, vDSP_Length(h))
                            }
                    }
                }
            }
        }
    }
}
