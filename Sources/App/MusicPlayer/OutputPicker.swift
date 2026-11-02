import AppKit
import Commands
import HALOutput
import Log
import Palette
import Settings

private let logger = moduleLogger()

/// The output picker's wiring: the devices found, followed as they come and go, the renderers a
/// search finds, and picking one through the config's output settings (ADR 0044).
extension AppDelegate {
    func watchOutputs(_ menu: MainMenu) {
        let outputMenu = OutputMenu()
        outputMenu.options = { [weak self] in
            guard let self else { return ([], .systemDefault) }
            return (outputOptionsNow(), currentOutput)
        }
        outputMenu.choose = { [weak self] in self?.chooseOutput($0) }
        outputMenu.opened = { [weak self] in self?.searchOutputs() }
        menu.liveMenus[AppMenus.outputMenuTitle]?.delegate = outputMenu
        self.outputMenu = outputMenu
        readDevices()
        do {
            deviceListWatch = try DeviceListWatch { [weak self] in self?.readDevices() }
        } catch {
            logger.error("can't follow the device list for the output picker: \(error)")
            browser?.report("The output picker won't follow devices as they come and go: \(error)")
        }
    }

    /// The output the config names now.
    var currentOutput: OutputChoice {
        guard let settings else { return .systemDefault }
        return OutputChoice(
            deviceUID: settings[\.outputDeviceUID], renderer: settings[\.outputRenderer])
    }

    func outputOptionsNow() -> [OutputOption] {
        outputOptions(devices: foundDevices, renderers: foundRenderers, current: currentOutput)
    }

    /// Writes the pick to the config, whose change handlers switch the output. The device goes
    /// first, so leaving a renderer for a device doesn't play a moment on the device before.
    func chooseOutput(_ choice: OutputChoice) {
        guard let settings else { return }
        let next = choice.settings(deviceUID: settings[\.outputDeviceUID])
        do {
            if settings[\.outputDeviceUID] != next.deviceUID {
                try settings.set(\.outputDeviceUID, to: next.deviceUID)
            }
            if settings[\.outputRenderer] != next.renderer {
                try settings.set(\.outputRenderer, to: next.renderer)
            }
        } catch {
            fail("Couldn't change the output", error)
        }
    }

    /// Starts one search for renderers, unless one is running, and lists what it finds.
    func searchOutputs() {
        guard outputSearch == nil else { return }
        outputSearch = Task { [weak self] in
            do {
                let found = try await searchRenderers()
                self?.foundRenderers = found.map { FoundOutput(id: $0.udn, name: $0.name) }
                self?.outputsChanged()
            } catch {
                logger.error("the renderer search for the output picker failed: \(error)")
            }
            self?.outputSearch = nil
        }
    }

    private func readDevices() {
        do {
            foundDevices = try AudioDevice.outputDevices().map {
                FoundOutput(id: $0.uid, name: $0.name)
            }
        } catch {
            logger.error("can't list the output devices: \(error)")
            browser?.report("Couldn't list the output devices: \(error)")
        }
        outputsChanged()
    }

    private func outputsChanged() {
        outputMenu?.refresh()
        if let dispatcher { settingsWindow?.reload(bindings: dispatcher.bindings) }
    }
}

/// The palette rows that pick an output, "Output: <name>".
func outputItems(_ options: [OutputOption], current: OutputChoice) -> [PaletteItem] {
    options.map {
        PaletteItem(
            kind: .output, key: $0.choice.text, title: "\(AppMenus.outputMenuTitle): \($0.title)",
            detail: $0.choice == current ? "In use" : AppMenus.outputMenuTitle)
    }
}
