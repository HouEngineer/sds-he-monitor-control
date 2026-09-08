//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import Cocoa
import Foundation

struct CliHandler {
  enum Subcommand: String {
    case list, get, set, help
  }

  enum Selector {
    case id(CGDirectDisplayID)
    case name(String)
    case index(Int)
    case all
  }

  let subcommand: Subcommand
  let selector: Selector?
  let value: Int?
  let json: Bool
  let real: Bool
  let parseError: String?

  /// Returns nil when the arguments don't look like a CLI invocation (no known subcommand) so the GUI starts normally.
  init?(arguments: [String]) {
    guard arguments.count > 1, let subcommand = Subcommand(rawValue: arguments[1].lowercased()) else {
      return nil
    }
    self.subcommand = subcommand
    var selector: Selector?
    var value: Int?
    var json = false
    var real = false
    var positional: [String] = []
    var parseError: String?
    let args = Array(arguments.dropFirst(2))
    var index = 0
    while index < args.count {
      let token = args[index]
      index += 1
      switch token {
      case "--json":
        json = true
      case "--real":
        real = true
      case "--all":
        selector = .all
      case "--id":
        guard index < args.count, let id = CGDirectDisplayID(args[index]) else {
          if parseError == nil { parseError = "--id requires a numeric display ID (see `list`)" }
          continue
        }
        index += 1
        selector = .id(id)
      case "--name":
        guard index < args.count else {
          if parseError == nil { parseError = "--name requires a display name substring" }
          continue
        }
        selector = .name(args[index])
        index += 1
      case "--index":
        guard index < args.count, let position = Int(args[index]), position >= 0 else {
          if parseError == nil { parseError = "--index requires a non-negative number" }
          continue
        }
        index += 1
        selector = .index(position)
      default:
        positional.append(token)
      }
    }
    switch subcommand {
    case .list, .help:
      if !positional.isEmpty, parseError == nil {
        parseError = "Unexpected argument: \(positional[0])"
      }
    case .get:
      if selector == nil, positional.count == 1 {
        selector = .name(positional.removeFirst())
      }
      if !positional.isEmpty, parseError == nil {
        parseError = "Unexpected argument: \(positional[0])"
      }
      if selector == nil, parseError == nil {
        parseError = "A display selector is required; pass a display name directly (e.g. get Q27P10) or use --id/--index/--all"
      }
    case .set:
      if selector == nil, positional.count == 2 {
        selector = .name(positional.removeFirst())
      }
      if positional.count != 1, parseError == nil {
        parseError = "set requires a display and a brightness value between 0 and 100 (e.g. set Q27P10 50)"
      } else if let parsed = Int(positional.first ?? ""), (0 ... 100).contains(parsed) {
        value = parsed
      } else if parseError == nil {
        parseError = "Brightness must be an integer between 0 and 100"
      }
      if selector == nil, parseError == nil {
        parseError = "A display selector is required; pass a display name directly (e.g. set Q27P10 50) or use --id/--name/--index/--all"
      }
    }
    self.selector = selector
    self.value = value
    self.json = json
    self.real = real
    self.parseError = parseError
  }

  func run() -> Int32 {
    if let parseError {
      CliHandler.stderrPrint("Error: \(parseError)")
      CliHandler.printUsage()
      return 2
    }
    switch self.subcommand {
    case .help:
      CliHandler.printUsage()
      return 0
    case .list:
      return self.runList()
    case .get:
      return self.runGet()
    case .set:
      return self.runSet()
    }
  }

  /// Builds the display list the same way the GUI does, minus any DDC I/O during setup (blocked by app.isCli).
  private func configureDisplayStack() {
    DisplayManager.shared.configureDisplays()
    DisplayManager.shared.addDisplayCounterSuffixes()
    DisplayManager.shared.updateArm64AVServices()
    for otherDisplay in DisplayManager.shared.getOtherDisplays() where (!otherDisplay.isSw() && !otherDisplay.readPrefAsBool(key: .unavailableDDC, for: .brightness)) || otherDisplay.isSw() {
      otherDisplay.setupCurrentAndMaxValues(command: .brightness, firstrun: false)
    }
  }

  private func runList() -> Int32 {
    self.configureDisplayStack()
    let displays = DisplayManager.shared.getAllDisplays()
    if self.json {
      let items: [[String: Any]] = displays.map { display in
        [
          "id": display.identifier,
          "name": display.name,
          "type": self.typeLabel(for: display),
          "vendor": display.vendorNumber ?? 0,
          "model": display.modelNumber ?? 0,
          "serial": display.serialNumber ?? 0,
          "brightness": Int((self.brightnessValue(for: display) * 100).rounded()),
        ]
      }
      if let data = try? JSONSerialization.data(withJSONObject: items, options: [.sortedKeys]), let output = String(data: data, encoding: .utf8) {
        print(output)
      } else {
        CliHandler.stderrPrint("Error: failed to serialize JSON output")
        return 1
      }
      return 0
    }
    let header = ["ID", "NAME", "TYPE", "VENDOR", "MODEL", "SERIAL", "BRIGHTNESS"]
    print([CliHandler.pad(header[0], 12), CliHandler.pad(header[1], 24), CliHandler.pad(header[2], 8), CliHandler.pad(header[3], 7), CliHandler.pad(header[4], 7), CliHandler.pad(header[5], 9), header[6]].joined(separator: " "))
    for display in displays {
      let brightness = Int((self.brightnessValue(for: display) * 100).rounded())
      let columns = [
        CliHandler.pad(String(display.identifier), 12),
        CliHandler.pad(CliHandler.truncated(display.name, to: 24), 24),
        CliHandler.pad(self.typeLabel(for: display), 8),
        CliHandler.pad(String(display.vendorNumber ?? 0), 7),
        CliHandler.pad(String(display.modelNumber ?? 0), 7),
        CliHandler.pad(String(display.serialNumber ?? 0), 9),
        "\(brightness)%",
      ]
      print(columns.joined(separator: " "))
    }
    return 0
  }

  private func runGet() -> Int32 {
    self.configureDisplayStack()
    let displays = DisplayManager.shared.getAllDisplays()
    guard let targets = self.resolveTargets(in: displays) else {
      return 1
    }
    for target in targets {
      let brightness = Int((self.brightnessValue(for: target) * 100).rounded())
      if targets.count > 1 {
        print("\(target.identifier)\t\(brightness)")
      } else {
        print(brightness)
      }
    }
    return 0
  }

  private func runSet() -> Int32 {
    self.configureDisplayStack()
    let displays = DisplayManager.shared.getAllDisplays()
    guard let targets = self.resolveTargets(in: displays) else {
      return 1
    }
    // If a MonitorControl GUI instance is running, delegate to it: virtual/software-dimmed displays are shaded by
    // an on-screen window owned by the GUI process, which dies with a short-lived CLI process.
    if let guiPid = CliHandler.findRunningGuiInstancePid() {
      if self.setBrightnessViaGui(targets: targets) {
        return 0
      }
      CliHandler.stderrPrint("Warning: running MonitorControl (pid \(guiPid)) did not respond; applying locally instead. Virtual displays need this custom build running as the app.")
    }
    var hadFailure = false
    for target in targets {
      if target.isVirtual || target.readPrefAsBool(key: .avoidGamma) {
        CliHandler.stderrPrint("Warning: '\(target.name)' is dimmed by an on-screen shade, which only the running MonitorControl app can display; start the app for this to take effect.")
      }
      // setDirectBrightness is the synchronous path: no smooth-transition run loop dependency, no gamma interference alert.
      if !target.setDirectBrightness(Float(self.value ?? 0) / 100) {
        CliHandler.stderrPrint("Error: failed to set brightness for '\(target.name)'")
        hadFailure = true
      }
    }
    // Wait for queued DDC writes to complete before exiting.
    DisplayManager.shared.globalDDCQueue.sync(flags: .barrier) {}
    return hadFailure ? 1 : 0
  }

  /// Sends the set command to the running GUI via a distributed notification and waits for its ack.
  private func setBrightnessViaGui(targets: [Display]) -> Bool {
    guard let value = self.value else {
      return false
    }
    let nonce = UUID().uuidString
    guard let payloadData = try? JSONSerialization.data(withJSONObject: ["command": "setBrightness", "ids": targets.map { Int($0.identifier) }, "value": value, "nonce": nonce] as [String: Any]), let payload = String(data: payloadData, encoding: .utf8) else {
      return false
    }
    var acked = false
    var ackOk = false
    let observer = DistributedNotificationCenter.default().addObserver(forName: CliHandler.ackNotificationName, object: nil, queue: nil) { note in
      guard let userInfo = note.userInfo as? [String: String], let json = userInfo["payload"], let data = json.data(using: .utf8), let ack = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], ack["nonce"] as? String == nonce else {
        return
      }
      acked = true
      ackOk = ack["ok"] as? Bool ?? false
    }
    DistributedNotificationCenter.default().postNotificationName(CliHandler.commandNotificationName, object: nil, userInfo: ["payload": payload], deliverImmediately: true)
    // Distributed notifications are delivered through the run loop, so pump it while waiting for the ack.
    let deadline = Date().addingTimeInterval(3.0)
    while !acked, Date() < deadline {
      RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    DistributedNotificationCenter.default().removeObserver(observer)
    return acked && ackOk
  }

  static let commandNotificationName = NSNotification.Name("MonitorControl.CliCommand")
  static let ackNotificationName = NSNotification.Name("MonitorControl.CliAck")

  static func findRunningGuiInstancePid() -> pid_t? {
    guard let bundleId = Bundle.main.bundleIdentifier else {
      return nil
    }
    return NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
      $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
    }?.processIdentifier
  }

  private func resolveTargets(in displays: [Display]) -> [Display]? {
    guard let selector = self.selector else {
      CliHandler.stderrPrint("Error: a display selector is required (--id, --name, --index or --all)")
      return nil
    }
    if displays.isEmpty {
      CliHandler.stderrPrint("Error: no displays found")
      return nil
    }
    switch selector {
    case .all:
      return displays
    case .id(let id):
      if let display = displays.first(where: { $0.identifier == id }) {
        return [display]
      }
      CliHandler.stderrPrint("Error: no display with ID \(id) (run `list` to see IDs)")
      return nil
    case .index(let position):
      guard position < displays.count else {
        CliHandler.stderrPrint("Error: display index \(position) out of range (0-\(displays.count - 1))")
        return nil
      }
      return [displays[position]]
    case .name(let substring):
      let lowered = substring.lowercased()
      let matches = displays.filter { $0.name.lowercased().contains(lowered) }
      if matches.isEmpty {
        CliHandler.stderrPrint("Error: no display name contains '\(substring)' (run `list` to see names)")
        return nil
      }
      return matches
    }
  }

  private func typeLabel(for display: Display) -> String {
    if display.isDummy {
      return "dummy"
    }
    if display.isVirtual {
      return "virtual"
    }
    if display is AppleDisplay {
      return "apple"
    }
    if let otherDisplay = display as? OtherDisplay, otherDisplay.isSw() {
      return "sw"
    }
    return "ddc"
  }

  private func brightnessValue(for display: Display) -> Float {
    if let appleDisplay = display as? AppleDisplay {
      return self.real ? appleDisplay.getAppleBrightness() : appleDisplay.getBrightness()
    }
    if let otherDisplay = display as? OtherDisplay, self.real, !otherDisplay.isSw() {
      if let ddcValue = otherDisplay.readDDCValues(for: .brightness, tries: 5, minReplyDelay: nil)?.current {
        return otherDisplay.convDDCToValue(for: .brightness, from: ddcValue)
      }
      CliHandler.stderrPrint("Warning: DDC read failed for '\(display.name)', falling back to stored value")
    }
    return display.getBrightness()
  }

  private static func truncated(_ text: String, to maxLength: Int) -> String {
    text.count <= maxLength ? text : String(text.prefix(maxLength - 1)) + "…"
  }

  private static func pad(_ text: String, _ length: Int) -> String {
    text.padding(toLength: length, withPad: " ", startingAt: 0)
  }

  private static func stderrPrint(_ message: String) {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
  }

  private static func printUsage() {
    print("""
    Usage: MonitorControl <command> [options]

    Commands:
      list [--json] [--real]      List displays (id, name, type, brightness)
      get <display> [--real]      Print brightness (0-100) of the display
      set <display> <0-100>       Set brightness of the display
      help                        Show this help

    <display> is a display name substring (e.g. Q27P10, case-insensitive, may match several)
    or one of the following selectors:
      --id <id>     Display ID shown by `list` (NOTE: IDs change on display reconfiguration)
      --name <text> Displays whose name contains <text> (case-insensitive, may match several)
      --index <n>   Zero-based position in the `list` output (may change on reconfiguration)
      --all         All displays

    Options:
      --json        Machine-readable single-line JSON array (list only)
      --real        Read brightness from the display via DDC instead of the stored value (slower, may fail)

    Examples:
      MonitorControl list
      MonitorControl set Q27P10 50
      MonitorControl set --name "DELL" 75
      MonitorControl set --all 30
      MonitorControl get Q27P10 --real

    Tip: run the binary inside the app bundle directly so output lands in your terminal, e.g.
      alias mcctl='/Applications/MonitorControl.app/Contents/MacOS/MonitorControl'
    Do NOT symlink the binary: it would break Bundle.main and the app preferences would not be found.
    """)
  }
}
