import SwiftUI

/// 그래프 계열 색 (고정 순서, dataviz 기본 팔레트). 텍스트에는 쓰지 않는다.
enum ChartPalette {
    static let blue = Color(red: 0x2a / 255, green: 0x78 / 255, blue: 0xd6 / 255)
    static let orange = Color(red: 0xeb / 255, green: 0x68 / 255, blue: 0x34 / 255)
    static let aqua = Color(red: 0x1b / 255, green: 0xaf / 255, blue: 0x7a / 255)
    static let yellow = Color(red: 0xed / 255, green: 0xa1 / 255, blue: 0x00 / 255)
    static let magenta = Color(red: 0xe8 / 255, green: 0x7b / 255, blue: 0xa4 / 255)
    static let violet = Color(red: 0x4a / 255, green: 0x3a / 255, blue: 0xa7 / 255)
    static let line = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
}
