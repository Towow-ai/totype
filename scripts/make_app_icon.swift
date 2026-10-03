// Builds VerbatimVoice/Resources/AppIcon.icns from the design-v2 1024 artwork.
//
//   swift scripts/make_app_icon.swift <icon-1024-light.png> <output.icns>
//
// The design PNG is a full-bleed square (the iOS layer). macOS app icons carry their own
// shape, so the artwork is scaled into the 824×824 body of the 1024 macOS grid (100pt
// margin) and clipped with SwiftUI's continuous-corner rounded rectangle (radius 185.4).
// No shadow or highlight is added (DESIGN.md §3.3, §9).
import AppKit
import SwiftUI

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: make_app_icon.swift <icon-1024.png> <out.icns>\n".utf8))
    exit(2)
}
let source = URL(fileURLWithPath: arguments[1])
let output = URL(fileURLWithPath: arguments[2])
guard let artwork = NSImage(contentsOf: source),
      let artworkCG = artwork.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write(Data("cannot read \(source.path)\n".utf8))
    exit(1)
}

func render(pixels: Int) -> Data? {
    let scale = CGFloat(pixels) / 1024
    guard let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.interpolationQuality = .high
    context.scaleBy(x: scale, y: scale)
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = RoundedRectangle(cornerRadius: 185.4, style: .continuous).path(in: body).cgPath
    context.addPath(shape)
    context.clip()
    context.draw(artworkCG, in: body)
    guard let image = context.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
}

let iconset = FileManager.default.temporaryDirectory
    .appendingPathComponent("VerbatimVoice-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

for points in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let name = factor == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        guard let data = render(pixels: points * factor) else { exit(1) }
        try data.write(to: iconset.appendingPathComponent(name))
    }
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try process.run()
process.waitUntilExit()
exit(process.terminationStatus)
