#!/usr/bin/env swift
import AppKit
import Foundation

// Generates AudioSplit's app icon as source rather than shipping an opaque
// binary nobody can edit. Run:  swift Scripts/make-icon.swift
//
// The mark is the app in one glyph: a single source splitting into two
// destinations. It deliberately matches the Routes sidebar symbol
// (arrow.triangle.branch) so the icon and the UI say the same thing.
//
// Geometry follows Apple's macOS grid — a 1024 canvas with the rounded square
// inset to 824 and a 185pt corner radius — so it sits correctly next to system
// icons in the Dock rather than looking oversized.

let canvas: CGFloat = 1024
let inset: CGFloat = 100
let side = canvas - inset * 2
let cornerRadius: CGFloat = 185

func drawIcon(into context: CGContext) {
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    let plate = CGRect(x: inset, y: inset, width: side, height: side)
    let platePath = CGPath(
        roundedRect: plate,
        cornerWidth: cornerRadius,
        cornerHeight: cornerRadius,
        transform: nil
    )

    // Background gradient. Indigo to violet reads as a system utility without
    // looking like a media player.
    context.saveGState()
    context.addPath(platePath)
    context.clip()
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(red: 0.36, green: 0.42, blue: 0.96, alpha: 1),
            CGColor(red: 0.42, green: 0.22, blue: 0.80, alpha: 1),
        ] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: plate.minX, y: plate.maxY),
        end: CGPoint(x: plate.maxX, y: plate.minY),
        options: []
    )
    context.restoreGState()

    // Hairline highlight along the top edge, the usual macOS plate treatment.
    context.saveGState()
    context.addPath(platePath)
    context.setLineWidth(6)
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.22))
    context.strokePath()
    context.restoreGState()

    // The fork: one node on the left, two on the right.
    let stroke: CGFloat = 54
    let nodeRadius: CGFloat = 70
    let sourceX: CGFloat = 330
    let midY: CGFloat = canvas / 2
    let splitX: CGFloat = 512
    let destinationX: CGFloat = 694
    let upperY: CGFloat = 690
    let lowerY: CGFloat = 334

    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.setLineWidth(stroke)
    context.setLineCap(.round)
    context.setLineJoin(.round)

    // Stem.
    context.move(to: CGPoint(x: sourceX, y: midY))
    context.addLine(to: CGPoint(x: splitX, y: midY))
    context.strokePath()

    // Two branches, curved so the split reads as a flow rather than a bracket.
    for endY in [upperY, lowerY] {
        context.move(to: CGPoint(x: splitX, y: midY))
        context.addCurve(
            to: CGPoint(x: destinationX, y: endY),
            control1: CGPoint(x: splitX + 110, y: midY),
            control2: CGPoint(x: destinationX - 110, y: endY)
        )
        context.strokePath()
    }

    // Nodes.
    for point in [
        CGPoint(x: sourceX, y: midY),
        CGPoint(x: destinationX, y: upperY),
        CGPoint(x: destinationX, y: lowerY),
    ] {
        context.fillEllipse(in: CGRect(
            x: point.x - nodeRadius,
            y: point.y - nodeRadius,
            width: nodeRadius * 2,
            height: nodeRadius * 2
        ))
    }
}

func render(size: Int) -> Data {
    let pixels = size
    guard let rep = NSBitmapImageRep(
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
    ), let context = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("could not create a bitmap context at \(size)px")
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let cg = context.cgContext
    let scale = CGFloat(pixels) / canvas
    cg.scaleBy(x: scale, y: scale)
    drawIcon(into: cg)
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("could not encode PNG at \(size)px")
    }
    return data
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// The names iconutil expects.
let variants: [(name: String, size: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    let url = iconset.appendingPathComponent("\(variant.name).png")
    try render(size: variant.size).write(to: url)
}

print("wrote \(variants.count) sizes to Resources/AppIcon.iconset")
