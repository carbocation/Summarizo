#!/usr/bin/env swift

import AppKit
import Foundation

struct IconSlot {
    let filename: String
    let pixels: Int
    let size: String
    let scale: String
}

let slots = [
    IconSlot(filename: "appicon-16.png", pixels: 16, size: "16x16", scale: "1x"),
    IconSlot(filename: "appicon-16@2x.png", pixels: 32, size: "16x16", scale: "2x"),
    IconSlot(filename: "appicon-32.png", pixels: 32, size: "32x32", scale: "1x"),
    IconSlot(filename: "appicon-32@2x.png", pixels: 64, size: "32x32", scale: "2x"),
    IconSlot(filename: "appicon-128.png", pixels: 128, size: "128x128", scale: "1x"),
    IconSlot(filename: "appicon-128@2x.png", pixels: 256, size: "128x128", scale: "2x"),
    IconSlot(filename: "appicon-256.png", pixels: 256, size: "256x256", scale: "1x"),
    IconSlot(filename: "appicon-256@2x.png", pixels: 512, size: "256x256", scale: "2x"),
    IconSlot(filename: "appicon-512.png", pixels: 512, size: "512x512", scale: "1x"),
    IconSlot(filename: "appicon-512@2x.png", pixels: 1024, size: "512x512", scale: "2x")
]

let fileManager = FileManager.default
let rootURL = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
let assetCatalogURL = rootURL.appendingPathComponent("Sources/Summarizo/Resources/Assets.xcassets", isDirectory: true)
let appIconSetURL = assetCatalogURL.appendingPathComponent("AppIcon.appiconset", isDirectory: true)

try fileManager.createDirectory(at: appIconSetURL, withIntermediateDirectories: true)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

let background = color(248, 250, 246)
let textColor = color(22, 31, 43)
let mutedTextColor = color(75, 85, 99)
let borderColor = color(18, 24, 38, 0.16)
let topBarColor = color(37, 99, 235)
let rightBarColor = color(16, 185, 129)
let bottomBarColor = color(245, 158, 11)
let leftBarColor = color(225, 29, 72)

func drawText(
    _ text: String,
    in rect: CGRect,
    font: NSFont,
    color: NSColor,
    alignment: NSTextAlignment = .center,
    kern: CGFloat = 0
) {
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.alignment = alignment
    paragraphStyle.lineBreakMode = .byClipping

    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: paragraphStyle,
        .kern: kern
    ]

    (text as NSString).draw(in: rect, withAttributes: attributes)
}

func drawIcon(pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    guard let context = NSGraphicsContext.current?.cgContext else {
        fatalError("Unable to create drawing context.")
    }

    context.clear(CGRect(x: 0, y: 0, width: size, height: size))
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)

    let margin = size * 0.06
    let cardRect = CGRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)
    let cornerRadius = size * 0.19
    let cardPath = CGPath(roundedRect: cardRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -size * 0.018),
        blur: size * 0.045,
        color: color(15, 23, 42, 0.28).cgColor
    )
    context.addPath(cardPath)
    context.setFillColor(background.cgColor)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(cardPath)
    context.clip()

    context.setFillColor(background.cgColor)
    context.fill(cardRect)

    let bar = max(2, size * 0.088)
    context.setFillColor(topBarColor.cgColor)
    context.fill(CGRect(x: cardRect.minX, y: cardRect.maxY - bar, width: cardRect.width, height: bar))
    context.setFillColor(rightBarColor.cgColor)
    context.fill(CGRect(x: cardRect.maxX - bar, y: cardRect.minY, width: bar, height: cardRect.height))
    context.setFillColor(bottomBarColor.cgColor)
    context.fill(CGRect(x: cardRect.minX, y: cardRect.minY, width: cardRect.width, height: bar))
    context.setFillColor(leftBarColor.cgColor)
    context.fill(CGRect(x: cardRect.minX, y: cardRect.minY, width: bar, height: cardRect.height))

    context.setStrokeColor(borderColor.cgColor)
    context.setLineWidth(max(1, size * 0.006))
    context.addPath(cardPath)
    context.strokePath()
    context.restoreGState()

    let symbolFont = NSFont.systemFont(ofSize: size * 0.37, weight: .heavy)
    let symbolRect = CGRect(
        x: cardRect.minX + size * 0.14,
        y: cardRect.midY - size * 0.21,
        width: cardRect.width - size * 0.28,
        height: size * 0.42
    )
    drawText("Su", in: symbolRect, font: symbolFont, color: textColor, kern: -size * 0.018)

    if pixels >= 64 {
        let numberFont = NSFont.monospacedDigitSystemFont(ofSize: max(8, size * 0.062), weight: .semibold)
        let numberRect = CGRect(
            x: cardRect.minX + bar + size * 0.036,
            y: cardRect.maxY - bar - size * 0.105,
            width: size * 0.16,
            height: size * 0.075
        )
        drawText("16", in: numberRect, font: numberFont, color: mutedTextColor, alignment: .left)
    }

    if pixels >= 128 {
        let nameFont = NSFont.systemFont(ofSize: size * 0.052, weight: .semibold)
        let nameRect = CGRect(
            x: cardRect.minX + bar,
            y: cardRect.minY + bar + size * 0.045,
            width: cardRect.width - bar * 2,
            height: size * 0.07
        )
        drawText("Summarizo", in: nameRect, font: nameFont, color: mutedTextColor, kern: size * 0.003)
    }

    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("Unable to encode PNG.")
    }
    return data
}

let assetCatalogContents = """
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""

try assetCatalogContents.write(
    to: assetCatalogURL.appendingPathComponent("Contents.json"),
    atomically: true,
    encoding: .utf8
)

let imagesJSON = slots.map { slot -> String in
    """
    {
      "filename" : "\(slot.filename)",
      "idiom" : "mac",
      "scale" : "\(slot.scale)",
      "size" : "\(slot.size)"
    }
    """
}.joined(separator: ",\n")

let appIconContents = """
{
  "images" : [
\(imagesJSON.split(separator: "\n").map { "    \($0)" }.joined(separator: "\n"))
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""

try appIconContents.write(
    to: appIconSetURL.appendingPathComponent("Contents.json"),
    atomically: true,
    encoding: .utf8
)

for slot in slots {
    let data = drawIcon(pixels: slot.pixels)
    try data.write(to: appIconSetURL.appendingPathComponent(slot.filename), options: .atomic)
}

print("Generated \(slots.count) app icon PNGs in \(appIconSetURL.path)")
