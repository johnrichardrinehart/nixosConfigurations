// shotedit: Cmd+Shift+4 -> interactive screenshot that opens straight into the
// screenshot editor (Markup), as if the floating thumbnail had been clicked.
//
// macOS offers no setting for this: the editor only opens from a click on the
// thumbnail. So: grab Cmd+Shift+4 (darwin-configurations/mbp-host disables the
// system shortcut "Save picture of selected area as a file" and keeps the
// floating thumbnail on), run `screencapture -i -u`, wait for screencaptureui's
// thumbnail window, click it with a real mouse event, and put the cursor back.
// Escape / Ctrl (clipboard) produce no thumbnail and the wait simply times out.
//
// Needs Accessibility permission (posting mouse events). TCC keys the grant to
// the binary, so a rebuilt store path has to be granted again.
import AppKit
import Carbon
import CoreGraphics
import Foundation

// The thumbnail is invisible to CGWindowList (screencaptureui reports one
// full-screen overlay there), but Accessibility exposes it as its own small
// AXSystemDialog window -- the same thing a real click lands on.
func thumbnailBounds() -> CGRect? {
  guard let app = NSRunningApplication.runningApplications(
    withBundleIdentifier: "com.apple.screencaptureui").first else { return nil }
  let ax = AXUIElementCreateApplication(app.processIdentifier)
  var windows: CFTypeRef?
  guard AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &windows) == .success,
    let list = windows as? [AXUIElement] else { return nil }
  for w in list {
    var pos: CFTypeRef?, size: CFTypeRef?
    guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &pos) == .success,
      AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &size) == .success
    else { continue }
    var p = CGPoint.zero, s = CGSize.zero
    AXValueGetValue(pos as! AXValue, .cgPoint, &p)
    AXValueGetValue(size as! AXValue, .cgSize, &s)
    let r = CGRect(origin: p, size: s)
    if r.width > 40, r.width < 400, r.height < 300 { return r }
  }
  return nil
}

func click(_ p: CGPoint) {
  let restore = CGEvent(source: nil)?.location
  for t in [CGEventType.leftMouseDown, .leftMouseUp] {
    CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: .left)?
      .post(tap: .cghidEventTap)
    usleep(30_000)
  }
  if let restore { CGWarpMouseCursorPosition(restore) }
}

var busy = false

func capture() {
  if busy { return }
  busy = true
  DispatchQueue.global().async {
    defer { DispatchQueue.main.async { busy = false } }
    let sc = Process()
    sc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    // -u ignores the file argument and saves per the user's screenshot settings.
    sc.arguments = ["-i", "-u", NSTemporaryDirectory() + "shotedit-ignored.png"]
    do { try sc.run() } catch { return }
    sc.waitUntilExit()
    // The thumbnail slides in; wait until its bounds settle, then click it.
    var last: CGRect?
    for _ in 0..<40 {
      usleep(50_000)
      guard let r = thumbnailBounds() else { last = nil; continue }
      if r == last { click(CGPoint(x: r.midX, y: r.midY)); return }
      last = r
    }
  }
}

var hotKeyRef: EventHotKeyRef?
var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in capture(); return noErr }, 1, &spec, nil, nil)
let id = EventHotKeyID(signature: OSType(0x7368_6f74), id: 1)  // 'shot'
let status = RegisterEventHotKey(UInt32(kVK_ANSI_4), UInt32(cmdKey | shiftKey), id,
                                 GetApplicationEventTarget(), 0, &hotKeyRef)
guard status == noErr else {
  FileHandle.standardError.write("shotedit: RegisterEventHotKey failed (\(status))\n".data(using: .utf8)!)
  exit(1)
}
// Without Accessibility the thumbnail click is silently dropped; ask up front.
let axOpts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
if !AXIsProcessTrustedWithOptions(axOpts) {
  FileHandle.standardError.write("shotedit: grant Accessibility in System Settings\n".data(using: .utf8)!)
}

// Report the grant for provisioning: once trusted, write this binary's path
// to ~/.local/state/shotedit/trusted-binary. TCC keys the grant to the
// binary, so a stale path there means the current build still needs one.
// Until then, recheck every few seconds; the grant applies without a restart.
func recordTrust() -> Bool {
  guard AXIsProcessTrusted(), let exe = Bundle.main.executablePath else { return false }
  let dir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".local/state/shotedit", isDirectory: true)
  try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  try? (exe + "\n").write(to: dir.appendingPathComponent("trusted-binary"), atomically: true, encoding: .utf8)
  return true
}
if !recordTrust() {
  Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { timer in
    if recordTrust() { timer.invalidate() }
  }
}
NSApplication.shared.setActivationPolicy(.prohibited)
NSApplication.shared.run()
