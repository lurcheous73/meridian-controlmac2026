import AppKit
import Foundation

let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
let rect = NSRect(origin: .zero, size: size)
NSColor.black.setFill()
NSBezierPath(roundedRect: rect.insetBy(dx: 22, dy: 22), xRadius: 180, yRadius: 180).fill()

let border = NSBezierPath(roundedRect: rect.insetBy(dx: 28, dy: 28), xRadius: 170, yRadius: 170)
border.lineWidth = 18
NSColor(calibratedWhite: 0.72, alpha: 1.0).setStroke()
border.stroke()

let p1 = NSMutableParagraphStyle(); p1.alignment = .center
let attrsM: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 470, weight: .bold),
    .foregroundColor: NSColor.white,
    .paragraphStyle: p1
]
let attrsY: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 210, weight: .bold),
    .foregroundColor: NSColor.white,
    .paragraphStyle: p1,
    .kern: 6
]
("M" as NSString).draw(in: NSRect(x: 105, y: 330, width: 814, height: 520), withAttributes: attrsM)
("2026" as NSString).draw(in: NSRect(x: 110, y: 115, width: 804, height: 245), withAttributes: attrsY)
image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("M2026-1024.png")
try png.write(to: output)
