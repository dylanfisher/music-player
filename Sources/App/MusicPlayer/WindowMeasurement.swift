import AppKit
import Artwork
import Darwin
import Foundation
import Library
import LibraryBrowser

/// `--measure-window`: what Bench's window benchmarks read. Once the table first draws rows it
/// records the time since the process started and the memory in use, then scrolls through
/// every row with album art loaded for each album, records memory again, prints one JSON line
/// and quits.
@MainActor
enum WindowMeasurement {
    static func run(browser: LibraryBrowser, artwork: ArtworkLoader) {
        let launchSeconds = Date().timeIntervalSince1970 - processStartSeconds()
        let loadedMB = footprintMB()
        var rows = 0
        var albums: Set<Int64> = []
        var artImages = 0
        var artFailures = 0
        browser.scrollThroughEveryRow { row in
            rows += 1
            guard let art = row.art, albums.insert(row.albumID ?? -row.id).inserted else { return }
            do {
                _ = try artwork.image(art, path: row.path)
                artImages += 1
            } catch {
                artFailures += 1
            }
        }
        let report = WindowReport(
            launchSeconds: launchSeconds, loadedMB: loadedMB, scrolledMB: footprintMB(),
            rows: rows, artImages: artImages, artFailures: artFailures)
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
