// AgentLight icon: a head, the left half a schematic robot, the right half a traffic light.
//   swift scripts/make-icon.swift OUT_DIR   → OUT_DIR/AgentLight.icns and icon-1024.png
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func gradient(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

/// Drawn in a 1024×1024 space, origin at the bottom left.
func draw(_ ctx: CGContext) {
    // Backplate on the macOS grid: 824×824, corner radius ~185
    let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    let platePath = CGPath(roundedRect: plate, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(platePath)
    ctx.setFillColor(color(0x1B2233))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(platePath)
    ctx.clip()
    gradient(ctx, [color(0x2C3A55), color(0x141A28)], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100))
    ctx.restoreGState()

    // Head
    let head = CGRect(x: 232, y: 236, width: 560, height: 520)
    let headPath = CGPath(roundedRect: head, cornerWidth: 130, cornerHeight: 130, transform: nil)
    let mid = head.midX

    // Antenna (above the left half)
    ctx.setStrokeColor(color(0xB9C4D6))
    ctx.setLineWidth(18)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: 372, y: head.maxY - 4))
    ctx.addLine(to: CGPoint(x: 372, y: head.maxY + 70))
    ctx.strokePath()
    ctx.setFillColor(color(0x5EE6FF))
    ctx.setShadow(offset: .zero, blur: 30, color: color(0x5EE6FF, 0.9))
    ctx.fillEllipse(in: CGRect(x: 372 - 26, y: head.maxY + 62, width: 52, height: 52))
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    // Bolt ear on the left
    let ear = CGRect(x: head.minX - 46, y: head.midY - 70, width: 70, height: 140)
    ctx.addPath(CGPath(roundedRect: ear, cornerWidth: 26, cornerHeight: 26, transform: nil))
    ctx.setFillColor(color(0x8E9AB0))
    ctx.fillPath()

    // Left half — robot metal
    ctx.saveGState()
    ctx.addPath(headPath)
    ctx.clip()
    ctx.clip(to: CGRect(x: head.minX, y: head.minY, width: mid - head.minX, height: head.height))
    gradient(ctx, [color(0xE4EAF3), color(0xAEB9CC)], from: CGPoint(x: 0, y: head.maxY), to: CGPoint(x: 0, y: head.minY))
    ctx.restoreGState()

    // Right half — black traffic light housing
    ctx.saveGState()
    ctx.addPath(headPath)
    ctx.clip()
    ctx.clip(to: CGRect(x: mid, y: head.minY, width: head.maxX - mid, height: head.height))
    gradient(ctx, [color(0x2A2F38), color(0x101318)], from: CGPoint(x: 0, y: head.maxY), to: CGPoint(x: 0, y: head.minY))
    ctx.restoreGState()

    // Seam down the middle
    ctx.setStrokeColor(color(0x5C6880))
    ctx.setLineWidth(8)
    ctx.move(to: CGPoint(x: mid, y: head.minY + 6))
    ctx.addLine(to: CGPoint(x: mid, y: head.maxY - 6))
    ctx.strokePath()

    // Robot eye
    let eyeC = CGPoint(x: 382, y: 560)
    ctx.setFillColor(color(0x1B2233))
    ctx.fillEllipse(in: CGRect(x: eyeC.x - 72, y: eyeC.y - 72, width: 144, height: 144))
    ctx.setFillColor(color(0x5EE6FF))
    ctx.setShadow(offset: .zero, blur: 34, color: color(0x5EE6FF, 0.9))
    ctx.fillEllipse(in: CGRect(x: eyeC.x - 44, y: eyeC.y - 44, width: 88, height: 88))
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    ctx.setFillColor(color(0xFFFFFF, 0.85))
    ctx.fillEllipse(in: CGRect(x: eyeC.x - 30, y: eyeC.y + 6, width: 26, height: 26))

    // Grille mouth (left half)
    let mouth = CGRect(x: 292, y: 330, width: mid - 292 - 34, height: 74)
    ctx.addPath(CGPath(roundedRect: mouth, cornerWidth: 22, cornerHeight: 22, transform: nil))
    ctx.setFillColor(color(0x1B2233))
    ctx.fillPath()
    ctx.setStrokeColor(color(0x5EE6FF, 0.75))
    ctx.setLineWidth(10)
    for i in 1...3 {
        let x = mouth.minX + mouth.width * CGFloat(i) / 4
        ctx.move(to: CGPoint(x: x, y: mouth.minY + 16))
        ctx.addLine(to: CGPoint(x: x, y: mouth.maxY - 16))
    }
    ctx.strokePath()

    // Right half — three lights with visors
    let lights: [(UInt32, Bool)] = [(0xFF4D4D, true), (0xFFC83D, true), (0x3DDC6A, true)]
    let r: CGFloat = 52
    let cx = mid + (head.maxX - mid) / 2 - 6
    let ys: [CGFloat] = [head.maxY - 106, head.midY, head.minY + 106]
    for (i, (hex, lit)) in lights.enumerated() {
        let c = CGPoint(x: cx, y: ys[i])
        // socket
        ctx.setFillColor(color(0x05070A))
        ctx.fillEllipse(in: CGRect(x: c.x - r - 10, y: c.y - r - 10, width: 2 * (r + 10), height: 2 * (r + 10)))
        // light
        ctx.saveGState()
        if lit { ctx.setShadow(offset: .zero, blur: 46, color: color(hex, 0.95)) }
        ctx.setFillColor(color(hex, lit ? 1 : 0.28))
        ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        ctx.restoreGState()
        if lit {
            ctx.setFillColor(color(0xFFFFFF, 0.55))
            ctx.fillEllipse(in: CGRect(x: c.x - 30, y: c.y + 12, width: 26, height: 19))
        }
        // visor on top
        ctx.saveGState()
        ctx.addArc(center: c, radius: r + 20, startAngle: .pi * 0.12, endAngle: .pi * 0.88, clockwise: false)
        ctx.setStrokeColor(color(0x3A414D))
        ctx.setLineWidth(12)
        ctx.setLineCap(.round)
        ctx.strokePath()
        ctx.restoreGState()
    }
}

func render(_ px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    draw(ctx)
    return ctx.makeImage()!
}

func png(_ img: CGImage, _ url: URL) {
    try! NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!.write(to: url)
}

let iconset = outDir.appendingPathComponent("AgentLight.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    png(render(base), iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    png(render(base * 2), iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
png(render(1024), outDir.appendingPathComponent("icon-1024.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", outDir.appendingPathComponent("AgentLight.icns").path]
try! p.run()
p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
exit(p.terminationStatus)
