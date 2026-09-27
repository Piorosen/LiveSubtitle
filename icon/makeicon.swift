// 앱 아이콘 생성: swift icon/makeicon.swift icon/icon_1024.png
import AppKit

let out = CommandLine.arguments[1]
let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }

// macOS 아이콘 그리드: 1024 캔버스 안 824 둥근 사각형 (여백 100)
let margin: CGFloat = 100
let rect = CGRect(x: margin, y: margin, width: S - 2*margin, height: S - 2*margin)
let radius: CGFloat = rect.width * 0.2237
let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

// 그림자
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 40, color: NSColor.black.withAlphaComponent(0.35).cgColor)
NSColor(red: 0.12, green: 0.13, blue: 0.25, alpha: 1).setFill()
shape.fill()
ctx.restoreGState()

// 배경 그라데이션 (남색 → 보라)
shape.addClip()
let grad = NSGradient(colors: [
    NSColor(red: 0.10, green: 0.11, blue: 0.24, alpha: 1),
    NSColor(red: 0.24, green: 0.18, blue: 0.50, alpha: 1),
    NSColor(red: 0.42, green: 0.26, blue: 0.62, alpha: 1),
])!
grad.draw(in: rect, angle: 90)

// 은은한 하이라이트 원
ctx.saveGState()
let glow = NSGradient(colors: [NSColor.white.withAlphaComponent(0.16), NSColor.white.withAlphaComponent(0)])!
glow.draw(in: NSBezierPath(ovalIn: CGRect(x: rect.midX - 420, y: rect.maxY - 380, width: 840, height: 620)), relativeCenterPosition: .zero)
ctx.restoreGState()

// 음성 파형 (연설자 목소리)
let heights: [CGFloat] = [70, 150, 250, 330, 210, 290, 160, 100]
let barW: CGFloat = 46, gap: CGFloat = 30
let totalW = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
var x = rect.midX - totalW / 2
let waveY = rect.minY + rect.height * 0.62
for h in heights {
    let bar = NSBezierPath(roundedRect: CGRect(x: x, y: waveY - h/2, width: barW, height: h), xRadius: barW/2, yRadius: barW/2)
    NSColor.white.withAlphaComponent(0.92).setFill()
    bar.fill()
    x += barW + gap
}

// 자막 띠
let strip = CGRect(x: rect.minX + 70, y: rect.minY + 95, width: rect.width - 140, height: 210)
let stripPath = NSBezierPath(roundedRect: strip, xRadius: 48, yRadius: 48)
NSColor.black.withAlphaComponent(0.42).setFill()
stripPath.fill()

// "EN → 한" 텍스트
let para = NSMutableParagraphStyle(); para.alignment = .center
let text = NSMutableAttributedString()
text.append(NSAttributedString(string: "EN ", attributes: [
    .font: NSFont.systemFont(ofSize: 118, weight: .heavy), .foregroundColor: NSColor(red: 1, green: 0.85, blue: 0.4, alpha: 1), .paragraphStyle: para]))
text.append(NSAttributedString(string: "→ ", attributes: [
    .font: NSFont.systemFont(ofSize: 100, weight: .bold), .foregroundColor: NSColor.white.withAlphaComponent(0.8), .paragraphStyle: para]))
text.append(NSAttributedString(string: "한", attributes: [
    .font: NSFont.systemFont(ofSize: 150, weight: .heavy), .foregroundColor: NSColor.white, .paragraphStyle: para]))
let size = text.size()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 14, color: NSColor.black.withAlphaComponent(0.6).cgColor)
text.draw(at: NSPoint(x: strip.midX - size.width/2, y: strip.midY - size.height/2 + 6))
ctx.restoreGState()

img.unlockFocus()
guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(2) }
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
