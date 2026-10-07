// Sets a display's resolution the way System Settings > Displays does, and
// as permanently: WindowServer remembers it for that display and restores it
// whenever the display is attached again.
//
//   display-mode list
//     Connected displays (vendor, model, current mode) and the sizes each
//     offers, so a display can be added to the configuration.
//   display-mode set <vendor> <model> <width> <height> <scale>
//     Switch the display with that vendor and model number to the mode that
//     "looks like" width x height points with a backing scale of 1 or 2 (2 is
//     HiDPI), at its highest refresh rate. A display that is not connected is
//     skipped.
import CoreGraphics
import Foundation

// Without this option the HiDPI ("looks like") modes are hidden.
let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary

func onlineDisplays() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetOnlineDisplayList(count, &ids, &count)
    return Array(ids.prefix(Int(count)))
}

func usableModes(_ display: CGDirectDisplayID) -> [CGDisplayMode] {
    ((CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode]) ?? [])
        .filter { $0.isUsableForDesktopGUI() }
}

func scale(_ mode: CGDisplayMode) -> Int { mode.pixelWidth / mode.width }

func describe(_ mode: CGDisplayMode) -> String {
    "\(mode.width)x\(mode.height) scale \(scale(mode)) (\(mode.pixelWidth)x\(mode.pixelHeight)) \(Int(mode.refreshRate.rounded())) Hz"
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("display-mode: \(message)\n".utf8))
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "list":
    for display in onlineDisplays() {
        let current = CGDisplayCopyDisplayMode(display).map(describe) ?? "unknown"
        print("vendor \(CGDisplayVendorNumber(display)) model \(CGDisplayModelNumber(display))"
            + (CGDisplayIsBuiltin(display) != 0 ? " (built-in)" : "") + ": \(current)")
        var seen = Set<String>()
        for mode in usableModes(display) {
            let size = "\(mode.width) \(mode.height) \(scale(mode))"
            if seen.insert(size).inserted { print("  \(size)") }
        }
    }

case "set" where args.count == 6:
    guard let vendor = UInt32(args[1]), let model = UInt32(args[2]),
        let width = Int(args[3]), let height = Int(args[4]), let wanted = Int(args[5])
    else { fail("set takes numbers: <vendor> <model> <width> <height> <scale>") }
    guard let display = onlineDisplays().first(where: {
        CGDisplayVendorNumber($0) == vendor && CGDisplayModelNumber($0) == model
    }) else {
        print("display-mode: display \(vendor)/\(model) is not connected; skipped")
        exit(0)
    }
    let matches = usableModes(display).filter {
        $0.width == width && $0.height == height && scale($0) == wanted
    }
    guard let mode = matches.max(by: { $0.refreshRate < $1.refreshRate }) else {
        fail("display \(vendor)/\(model) has no mode \(width)x\(height) at scale \(wanted)")
    }
    // Compared by value: a display can list identical modes under several IDs.
    if let current = CGDisplayCopyDisplayMode(display), describe(current) == describe(mode) {
        print("display-mode: display \(vendor)/\(model) is already \(describe(mode))")
        exit(0)
    }
    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success else { fail("cannot begin a display configuration") }
    CGConfigureDisplayWithDisplayMode(config, display, mode, nil)
    let status = CGCompleteDisplayConfiguration(config, .permanently)
    guard status == .success else { fail("WindowServer refused the mode (CGError \(status.rawValue))") }
    print("display-mode: display \(vendor)/\(model) set to \(describe(mode))")

default:
    fail("usage: display-mode list | display-mode set <vendor> <model> <width> <height> <scale>")
}
