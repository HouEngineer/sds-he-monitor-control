//
//  WindowAwareBrightnessManager.swift
//  MonitorControl
//
//  Brightness follows windows: displays with windows go to 100%, windowless displays dim
//  (reusing the brightness preset dim values). Dimming applies after the display stays windowless
//  for a delay (default 0.5s). Brightening needs a window that is settled (unchanged bounds since
//  the previous poll) and mostly on that display: during fullscreen/Space switch transitions macOS
//  reports the sliding windows at offsets that sweep across neighbouring displays, and those must
//  not flash a display to full brightness. Manual brightness changes take over a display until its
//  window state flips again.
//

import Cocoa
import os.log

final class WindowAwareBrightnessManager {
  private var running = false
  private var pollInterval: TimeInterval = 0.5

  /// A window only lights its display when at least this fraction of the window's area lies on it.
  /// Sliding Space-transition windows sweep across neighbouring displays with well under this coverage.
  private let litCoverageRatio: CGFloat = 0.75

  private var dimDelay: TimeInterval {
    prefs.object(forKey: PrefKey.windowAwareDimDelay.rawValue) == nil ? 0.5 : prefs.double(forKey: PrefKey.windowAwareDimDelay.rawValue)
  }

  private struct DisplayState {
    var lastAppliedLit: Bool // brightness state written to the display last
    var pendingDimSince: Date? // when the current windowless stretch began (dim candidate)
    var manualHold: Bool // user took over; cleared on the next window state flip
  }

  private struct WindowSignature: Hashable {
    let id: CGWindowID
    let rect: CGRect
  }

  private var previousWindows: Set<WindowSignature> = []

  private var states: [CGDirectDisplayID: DisplayState] = [:]

  /// Starts the poll loop if the feature is enabled. Idempotent; safe to call at every revival point (launch, reconfigure, wake).
  func start() {
    guard !self.running,
      prefs.bool(forKey: PrefKey.enableWindowAwareBrightness.rawValue),
      app.sleepID == 0,
      app.reconfigureID == 0
    else { return }
    self.running = true
    os_log("WindowAwareBrightness job started.", type: .info)
    self.poll()
  }

  /// Stops the loop without touching current brightness.
  func stop() {
    guard self.running else { return }
    self.running = false
    for key in self.states.keys { self.states[key]?.pendingDimSince = nil }
    self.previousWindows = []
    os_log("WindowAwareBrightness job stopped.", type: .info)
  }

  private func poll() {
    guard self.running else { return }
    guard app.sleepID == 0, app.reconfigureID == 0 else {
      // Same guard as writeDDCValues: die instead of writing during sleep/reconfigure; revived by start().
      self.running = false
      os_log("WindowAwareBrightness job died because of sleep or reconfiguration.", type: .info)
      return
    }
    self.evaluate()
    DispatchQueue.main.asyncAfter(deadline: .now() + self.pollInterval) { self.poll() }
  }

  private func evaluate() {
    guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return }
    let myPid = Int(getpid())
    var rawLit = Set<CGDirectDisplayID>() // any window attributed to a display, mid-animation included
    var settledLit = Set<CGDirectDisplayID>() // only windows that are stable and mostly on the display
    var currentWindows = Set<WindowSignature>()
    for info in windowList {
      // Layer 0 keeps app windows only; the menu bar, Dock, desktop and system UI are excluded.
      guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
      // Exclude our own shade / gamma enforcer windows.
      guard let pid = info[kCGWindowOwnerPID as String] as? Int, pid != myPid else { continue }
      guard let windowID = info[kCGWindowNumber as String] as? CGWindowID else { continue }
      guard let bounds = info[kCGWindowBounds as String] as? [String: Any],
        let x = bounds["X"] as? CGFloat, let y = bounds["Y"] as? CGFloat,
        let width = bounds["Width"] as? CGFloat, let height = bounds["Height"] as? CGFloat
      else { continue }
      guard width >= 1, height >= 1 else { continue }
      let windowRect = CGRect(x: x, y: y, width: width, height: height)
      let signature = WindowSignature(id: windowID, rect: windowRect)
      currentWindows.insert(signature)
      // kCGWindowBounds uses top-left origin (CG coordinates): compare with CGDisplayBounds, not NSScreen.frame.
      var bestDisplay: CGDirectDisplayID?
      var bestArea: CGFloat = 0
      for screen in NSScreen.screens {
        let intersection = windowRect.intersection(CGDisplayBounds(screen.displayID))
        guard !intersection.isNull else { continue }
        let area = intersection.width * intersection.height
        if area > bestArea {
          bestArea = area
          bestDisplay = screen.displayID
        }
      }
      guard let displayID = bestDisplay else { continue }
      let effective = DisplayManager.resolveEffectiveDisplayID(displayID)
      rawLit.insert(effective)
      // Settled = same bounds as the previous poll AND most of the window on the winning display.
      // Space-transition windows slide (bounds change every frame) and sweep a neighbouring display
      // with far less than litCoverageRatio of their area, so both checks exclude them.
      if self.previousWindows.contains(signature), bestArea >= self.litCoverageRatio * windowRect.width * windowRect.height {
        settledLit.insert(effective)
      }
    }
    self.previousWindows = currentWindows
    for display in DisplayManager.shared.displays
    where !display.readPrefAsBool(key: .isDisabled, for: .brightness) && !display.readPrefAsBool(key: .windowAwareExcluded, for: .brightness) {
      let effective = DisplayManager.resolveEffectiveDisplayID(display.identifier)
      self.apply(display: display, lit: settledLit.contains(effective), hasWindow: rawLit.contains(effective))
    }
  }

  private func apply(display: Display, lit: Bool, hasWindow: Bool) {
    let key = display.identifier
    guard var state = self.states[key] else {
      // First sighting: record only. Never stomp the user's current brightness on enable/reconfigure/wake.
      self.states[key] = DisplayState(lastAppliedLit: lit, pendingDimSince: nil, manualHold: false)
      return
    }
    defer { self.states[key] = state }
    if lit != state.lastAppliedLit {
      state.manualHold = false // window state flipped: auto control takes over again
    }
    if lit {
      state.pendingDimSince = nil
      if !state.lastAppliedLit, !state.manualHold, self.setBrightness(1, on: display) {
        state.lastAppliedLit = true
        os_log("WindowAwareBrightness lit display %{public}@", type: .info, String(key))
      }
    } else {
      // Dim only when the display has no attributed window at all. hasWindow stays true while
      // Space-transition windows slide across, so a lit display isn't dimmed mid-animation.
      if state.lastAppliedLit, !state.manualHold, !hasWindow {
        if state.pendingDimSince == nil { state.pendingDimSince = Date() }
        if Date().timeIntervalSince(state.pendingDimSince!) >= self.dimDelay {
          if self.setBrightness(MenuHandler.dimValue(for: display.name), on: display) {
            state.lastAppliedLit = false
            os_log("WindowAwareBrightness dimmed display %{public}@", type: .info, String(key))
          }
          state.pendingDimSince = nil
        }
      }
    }
  }

  /// Two-step write identical to brightnessPresetClicked: setBrightness + slider sync.
  /// Returns false when the write didn't go through so the state machine retries next tick.
  private func setBrightness(_ value: Float, on display: Display) -> Bool {
    guard display.setBrightness(value) else { return false }
    if let slider = display.sliderHandler[.brightness] {
      slider.setValue(value, displayID: display.identifier)
    }
    return true
  }

  /// Called from manual brightness paths (slider drag, media keys, preset buttons): the user takes over those displays until their window state flips.
  func noteManualBrightnessChange(on displays: [Display] = DisplayManager.shared.displays) {
    guard self.running else { return }
    for display in displays where self.states[display.identifier] != nil {
      self.states[display.identifier]?.manualHold = true
    }
  }
}
