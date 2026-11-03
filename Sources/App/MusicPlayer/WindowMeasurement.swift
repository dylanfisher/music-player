import AppKit
import Artwork
import Darwin
import Foundation
import Library
import LibraryBrowser

/// What the app measures once the table first draws rows, before it quits.
enum MeasurementKind {
    /// `--measure-window`.
    case window
    /// `--measure-scroll`, with `--art-delay-ms` added to each art read.
    case scroll(ScrollCase, artDelaySeconds: Double)
}

/// `--measure-window`: what Bench's window benchmarks read. Once the table first draws rows it
/// records the time since the process started and the memory in use, then scrolls through
/// every row as a scroll-bar drag does, timing each screenful, with album art loaded for each
/// album, records memory again, prints one JSON line and quits. `--measure-scroll` prints
/// `LibraryBrowser.measureScroll`'s report instead (ADR 0073).
@MainActor
enum WindowMeasurement {
    static func run(_ kind: MeasurementKind, browser: LibraryBrowser, artwork: ArtworkLoader) {
        switch kind {
        case .window: measureWindow(browser: browser, artwork: artwork)
        case .scroll(let scrollCase, let artDelaySeconds):
            Task {
                printAndQuit(
                    await browser.measureScroll(scrollCase, artDelaySeconds: artDelaySeconds))
            }
        }
    }

    private static func measureWindow(browser: LibraryBrowser, artwork: ArtworkLoader) {
        let launchSeconds = Date().timeIntervalSince1970 - processStartSeconds()
        let loadedMB = footprintMB()
        var rows = 0
        var albums: Set<Int64> = []
        var artImages = 0
        var artFailures = 0
        let scrollStepsMs = browser.scrollThroughEveryRow { row in
            rows += 1
            guard let art = row.art, albums.insert(row.albumID ?? -row.id).inserted else { return }
            do {
                _ = try artwork.image(art, path: row.path)
                artImages += 1
            } catch {
                artFailures += 1
            }
        }
        printAndQuit(
            WindowReport(
                launchSeconds: launchSeconds, loadedMB: loadedMB, scrolledMB: footprintMB(),
                scrollStepsMs: scrollStepsMs, rows: rows, artImages: artImages,
                artFailures: artFailures))
    }

    /// Prints `report` as one JSON line, which Bench reads, and quits.
    private static func printAndQuit(_ report: some Encodable) {
        do {
            FileHandle.standardOutput.write(try JSONEncoder().encode(report) + Data("\n".utf8))
        } catch {
            printError(error)
        }
        NSApp.terminate(nil)
    }

    /// When the kernel started this process, in seconds since 1970, so the launch time includes
    /// loading the binary and its libraries.
    private static func processStartSeconds() -> Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0 else {
            preconditionFailure("sysctl can't read this process's start time: \(errno)")
        }
        let start = info.kp_proc.p_un.__p_starttime
        return Double(start.tv_sec) + Double(start.tv_usec) / 1e6
    }

    /// This process's physical footprint, as Activity Monitor's Memory column shows it.
    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        precondition(result == KERN_SUCCESS, "task_info failed: \(result)")
        return Double(info.phys_footprint) / 1e6
    }
}
