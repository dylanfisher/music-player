import Accelerate

/// The short-time FFT: each window of `points` frames per channel, Hann-windowed, its power
/// averaged over the channels, kept as the spectrogram's cell maxima and summed for the
/// average spectrum.
final class SpectrumAccumulator {
    static let points = 8192
    /// 50% overlap.
    static let hopFrames = points / 2
    private static let log2Points = vDSP_Length(13)
    /// The bins kept, DC up to just under Nyquist, `binsPerRow` to each row.
    private static let bins = points / 2
    private static let binsPerRow = bins / Spectrogram.rows
    /// What a full-scale sine's bin holds after `vDSP_fft_zrip`, which returns twice the DFT,
    /// through a Hann window, whose gain is a half: so 0 dB is a full-scale sine.
    private static let fullScalePower = Float(points / 2) * Float(points / 2)

    let channels: Int
    /// The windows each column holds the maxima of: enough for the windows the file's stated
    /// length makes to fit the most columns, and doubled whenever more come, as from a VBR
    /// MP3 whose length is an estimate, so the columns always span the whole file.
    private var windowsPerColumn: Int
    private let setup: FFTSetup
    private var window = [Float](repeating: 0, count: points)
    private var windowed = [Float](repeating: 0, count: points)
    private var real = [Float](repeating: 0, count: bins)
    private var imaginary = [Float](repeating: 0, count: bins)
    private var binPower = [Float](repeating: 0, count: bins)
    private var framePower = [Float](repeating: 0, count: bins)
    private var rowPower = [Float](repeating: 0, count: Spectrogram.rows)
    private var powerSum = [Float](repeating: 0, count: bins)
    private var cellPower: [Float]
    private(set) var windows = 0

    init(channels: Int, expectedWindows: Int) {
        self.channels = channels
        let columns = Spectrogram.maximumColumns
        windowsPerColumn = max(1, (expectedWindows + columns - 1) / columns)
        cellPower = [Float](repeating: 0, count: columns * Spectrogram.rows)
        guard let setup = vDSP_create_fftsetup(Self.log2Points, FFTRadix(kFFTRadix2)) else {
            preconditionFailure("vDSP couldn't set up an FFT of \(Self.points) points")
        }
        self.setup = setup
        vDSP_hann_window(&window, vDSP_Length(Self.points), Int32(vDSP_HANN_DENORM))
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// The windows a file of `frames` frames makes: one, zero-padded, when it's shorter than one.
    static func windowCount(frames: Int64) -> Int {
        frames <= Int64(points) ? 1 : Int((frames - Int64(points)) / Int64(hopFrames)) + 1
    }

    /// Adds one window: `samples[channel]` holds `points` frames of each channel.
    func add(_ samples: [[Float]]) {
        vDSP_vclr(&framePower, 1, vDSP_Length(Self.bins))
        for channel in samples {
            vDSP_vmul(channel, 1, window, 1, &windowed, 1, vDSP_Length(Self.points))
            real.withUnsafeMutableBufferPointer { real in
                imaginary.withUnsafeMutableBufferPointer { imaginary in
                    var split = DSPSplitComplex(
                        realp: real.baseAddress!, imagp: imaginary.baseAddress!)
                    windowed.withUnsafeBytes { bytes in
                        vDSP_ctoz(
                            bytes.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1,
                            vDSP_Length(Self.bins))
                    }
                    vDSP_fft_zrip(setup, &split, 1, Self.log2Points, FFTDirection(FFT_FORWARD))
                    // The packed Nyquist bin, which isn't kept.
                    imaginary[0] = 0
                    vDSP_zvmags(&split, 1, &binPower, 1, vDSP_Length(Self.bins))
                }
            }
            vDSP_vadd(binPower, 1, framePower, 1, &framePower, 1, vDSP_Length(Self.bins))
        }
        var scale = 1 / (Float(channels) * Self.fullScalePower)
        vDSP_vsmul(framePower, 1, &scale, &framePower, 1, vDSP_Length(Self.bins))
        vDSP_vadd(framePower, 1, powerSum, 1, &powerSum, 1, vDSP_Length(Self.bins))
        framePower.withUnsafeBufferPointer { power in
            for row in 0..<Spectrogram.rows {
                vDSP_maxv(
                    power.baseAddress! + row * Self.binsPerRow, 1, &rowPower[row],
                    vDSP_Length(Self.binsPerRow))
            }
        }
        if windows / windowsPerColumn == Spectrogram.maximumColumns { fold() }
        let column = windows / windowsPerColumn
        cellPower.withUnsafeMutableBufferPointer { cells in
            let cell = cells.baseAddress! + column * Spectrogram.rows
            vDSP_vmax(rowPower, 1, cell, 1, cell, 1, vDSP_Length(Spectrogram.rows))
        }
        windows += 1
    }

    /// Halves the columns, each new one the maxima of two, for twice the windows a column.
    private func fold() {
        let rows = Spectrogram.rows
        cellPower.withUnsafeMutableBufferPointer { cells in
            let base = cells.baseAddress!
            for column in 0..<Spectrogram.maximumColumns / 2 {
                vDSP_vmax(
                    base + 2 * column * rows, 1, base + (2 * column + 1) * rows, 1,
                    base + column * rows, 1, vDSP_Length(rows))
            }
            let kept = Spectrogram.maximumColumns / 2 * rows
            vDSP_vclr(base + kept, 1, vDSP_Length(cells.count - kept))
        }
        windowsPerColumn *= 2
    }

    /// Each row's average power in dB, from the lowest row up.
    var averageRowDB: [Double] {
        let count = Float(max(1, windows))
        return (0..<Spectrogram.rows).map { row in
            let start = row * Self.binsPerRow
            let mean =
                powerSum[start..<start + Self.binsPerRow].reduce(0, +)
                / Float(Self.binsPerRow) / count
            return decibels(Double(mean))
        }
    }

    /// The spectrogram, as far as the windows reached.
    func spectrogram(nyquistHz: Double, durationSeconds: Double) -> Spectrogram {
        let reached = max(1, (windows + windowsPerColumn - 1) / windowsPerColumn)
        let cells = cellPower.prefix(reached * Spectrogram.rows).map {
            Spectrogram.cell(decibels(Double($0)))
        }
        return Spectrogram(
            columns: reached, cells: cells, averageDB: averageRowDB.map(Float.init),
            nyquistHz: nyquistHz, durationSeconds: durationSeconds)
    }
}

/// A power ratio in dB, with silence as a level far under any the scale shows.
func decibels(_ power: Double) -> Double {
    10 * log10(max(power, 1e-30))
}
