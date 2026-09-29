//
//  ax_help_audit.swift
//  Tools
//
//  Tooltip ("alt") audit of the running app through the macOS Accessibility API: walks every
//  window of a process and lists controls (buttons, checkboxes, segments, pop-ups, sliders,
//  menu buttons…) that have no tooltip (AXHelp) and icon-only controls without a label (or with
//  an SF Symbol name as label).
//  SwiftUI only exposes its full tree to an out-of-process assistive client, so this is a CLI
//  (the terminal running it needs Accessibility permission; the app itself stays sandboxed).
//
//    xcrun swiftc Tools/ax_help_audit.swift -o /private/tmp/claude-501/<you>/ax_help_audit
//    /private/tmp/claude-501/<you>/ax_help_audit <pid> [window title substring] [-v]
//    /private/tmp/claude-501/<you>/ax_help_audit <pid> -press "Edit Presets…"   (AXPress a control by name,
//                                        e.g. to open a sheet that has no DevScript command)
//
//  Exit status 0 = every control has a tooltip and a label.
//

import ApplicationServices
import Foundation

var rawArgs = Array(CommandLine.arguments.dropFirst())
var pressName: String?
if let i = rawArgs.firstIndex(of: "-press"), i + 1 < rawArgs.count {
    pressName = rawArgs[i + 1]
    rawArgs.removeSubrange(i...(i + 1))
}
let args = rawArgs.filter { $0 != "-v" }
let verbose = CommandLine.arguments.contains("-v")
guard let pidArg = args.first, let pid = pid_t(pidArg) else {
    print("usage: ax_help_audit <pid> [window title substring] [-v]")
    exit(2)
}
let windowFilter = args.count > 1 ? args[args.startIndex + 1] : nil
guard AXIsProcessTrusted() else { print("this process needs Accessibility permission"); exit(2) }

let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 5)

func attr<T>(_ e: AXUIElement, _ name: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success else { return nil }
    return value as? T
}

func frame(_ e: AXUIElement) -> CGRect {
    var p = CGPoint.zero, s = CGSize.zero
    if let v: AXValue = attr(e, kAXPositionAttribute) { AXValueGetValue(v, .cgPoint, &p) }
    if let v: AXValue = attr(e, kAXSizeAttribute) { AXValueGetValue(v, .cgSize, &s) }
    return CGRect(origin: p, size: s)
}

let controlRoles: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXSlider",
                                 "AXDisclosureTriangle", "AXIncrementor", "AXComboBox", "AXColorWell"]
/// Window chrome AppKit owns (traffic lights, toolbar overflow).
let chromeSubroles: Set<String> = ["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton", "AXToolbarButton"]

struct Found { let role: String; let name: String; let help: String; let frame: CGRect }

var skippedSystem = 0

/// Skipped as AppKit chrome: scroll bar arrows / page areas, outline disclosure triangles
/// (List rows; SwiftUI has no tooltip API for them), window buttons.
func walk(_ e: AXUIElement, depth: Int, inOutline: Bool = false, into found: inout [Found]) {
    guard depth < 80 else { return }
    let role: String = attr(e, kAXRoleAttribute) ?? ""
    let subrole: String = attr(e, kAXSubroleAttribute) ?? ""
    if role == "AXScrollBar" { return }
    if role == "AXIncrementor", controlRoles.contains(role) {   // its arrow buttons share the stepper's tooltip
        let label = [attr(e, kAXDescriptionAttribute) as String?, attr(e, kAXTitleAttribute) as String?]
            .compactMap { $0 }.first { !$0.isEmpty } ?? ""
        found.append(Found(role: "Incrementor", name: label, help: attr(e, kAXHelpAttribute) ?? "", frame: frame(e)))
        return
    }
    if controlRoles.contains(role), chromeSubroles.contains(subrole) || (inOutline && role == "AXDisclosureTriangle") {
        skippedSystem += 1
    } else if controlRoles.contains(role) {
        let label = [attr(e, kAXDescriptionAttribute) as String?, attr(e, kAXTitleAttribute) as String?]
            .compactMap { $0 }.first { !$0.isEmpty } ?? ""
        let help: String = attr(e, kAXHelpAttribute) ?? ""
        found.append(Found(role: role.replacingOccurrences(of: "AX", with: ""), name: label, help: help, frame: frame(e)))
    }
    let children: [AXUIElement] = attr(e, kAXChildrenAttribute) ?? []
    for c in children { walk(c, depth: depth + 1, inOutline: inOutline || role == "AXOutline", into: &found) }
}

let windows: [AXUIElement] = attr(app, kAXWindowsAttribute) ?? []

if let pressName {
    func find(_ e: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth < 80 else { return nil }
        let role: String = attr(e, kAXRoleAttribute) ?? ""
        let names = [attr(e, kAXDescriptionAttribute) as String?, attr(e, kAXTitleAttribute) as String?].compactMap { $0 }
        if controlRoles.contains(role), names.contains(pressName) { return e }
        for c in (attr(e, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { if let f = find(c, depth: depth + 1) { return f } }
        return nil
    }
    guard let target = windows.lazy.compactMap({ find($0, depth: 0) }).first else { print("no control '\(pressName)'"); exit(1) }
    let r = AXUIElementPerformAction(target, kAXPressAction as CFString)
    print("pressed '\(pressName)': \(r == .success ? "ok" : "error \(r.rawValue)")")
    exit(r == .success ? 0 : 1)
}
var problems = 0
for w in windows {
    let title: String = attr(w, kAXTitleAttribute) ?? ""
    if let windowFilter, !title.contains(windowFilter) { continue }
    var found: [Found] = []
    walk(w, depth: 0, into: &found)
    let noHelp = found.filter { $0.help.isEmpty }
    // An SF Symbol name used as the label ("rectangle.inset.filled") = icon-only control without a real label.
    let noLabel = found.filter { $0.name.isEmpty || ($0.name.contains(".") && !$0.name.contains(" ") && $0.name == $0.name.lowercased()) }
    print("window '\(title)': \(found.count) controls, \(noHelp.count) without tooltip, \(noLabel.count) without label")
    for f in noHelp { print("  NO TOOLTIP \(f.role) '\(f.name)' at \(f.frame.integral)") }
    for f in noLabel { print("  NO LABEL   \(f.role) tooltip='\(f.help)' at \(f.frame.integral)") }
    if verbose { for f in found where !f.help.isEmpty { print("  ok         \(f.role) '\(f.name)' — \(f.help)") } }
    problems += noHelp.count + noLabel.count
}
if windows.isEmpty { print("no windows (pid \(pid))") }
print("(skipped \(skippedSystem) AppKit chrome controls: window buttons, outline disclosure triangles)")
exit(problems == 0 ? 0 : 1)
