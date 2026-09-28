import Foundation
import Compression

/// 최소 zip 컨테이너 생성기 (pptx용). 외부 프로세스 없이 동작하므로 App Sandbox에서도 쓸 수 있다.
/// 항목은 DEFLATE(Compression 프레임워크의 raw deflate)로 압축하되, 줄어들지 않으면(JPEG 등) STORED로 넣는다.
struct ZipWriter {
    private var data = Data()
    private var central = Data()
    private var count = 0

    /// 파일 추가. `path`는 zip 안 경로("ppt/slides/slide1.xml"), 슬래시 구분.
    mutating func add(_ path: String, _ content: Data, compress: Bool = true) {
        let name = Data(path.utf8)
        let crc = Self.crc32(content)
        var method: UInt16 = 0
        var payload = content
        if compress, !content.isEmpty, let d = Self.deflate(content), d.count < content.count {
            method = 8
            payload = d
        }
        let (time, date) = Self.dosDateTime(Date())
        let offset = UInt32(data.count)
        let flags: UInt16 = 0x0800          // 이름이 UTF-8

        // 로컬 파일 헤더
        var h = Data()
        h.u32(0x04034b50); h.u16(20); h.u16(flags); h.u16(method); h.u16(time); h.u16(date)
        h.u32(crc); h.u32(UInt32(payload.count)); h.u32(UInt32(content.count))
        h.u16(UInt16(name.count)); h.u16(0)
        h.append(name)
        data.append(h)
        data.append(payload)

        // 중앙 디렉터리 항목
        var c = Data()
        c.u32(0x02014b50); c.u16(20); c.u16(20); c.u16(flags); c.u16(method); c.u16(time); c.u16(date)
        c.u32(crc); c.u32(UInt32(payload.count)); c.u32(UInt32(content.count))
        c.u16(UInt16(name.count)); c.u16(0); c.u16(0); c.u16(0); c.u16(0); c.u32(0); c.u32(offset)
        c.append(name)
        central.append(c)
        count += 1
    }

    mutating func add(_ path: String, _ text: String) {
        add(path, Data(text.utf8))
    }

    /// 완성된 zip 바이트
    func finish() -> Data {
        var out = data
        let cdOffset = UInt32(out.count)
        out.append(central)
        var e = Data()
        e.u32(0x06054b50); e.u16(0); e.u16(0); e.u16(UInt16(count)); e.u16(UInt16(count))
        e.u32(UInt32(central.count)); e.u32(cdOffset); e.u16(0)
        out.append(e)
        return out
    }

    // MARK: 내부

    /// raw DEFLATE (zlib 헤더 없음) — zip method 8
    private static func deflate(_ src: Data) -> Data? {
        let cap = src.count + src.count / 8 + 64
        var dst = [UInt8](repeating: 0, count: cap)
        let n = src.withUnsafeBytes { s -> Int in
            compression_encode_buffer(&dst, cap, s.bindMemory(to: UInt8.self).baseAddress!, src.count, nil, COMPRESSION_ZLIB)
        }
        return n > 0 ? Data(dst[0..<n]) : nil
    }

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ d: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in d { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }

    private static func dosDateTime(_ date: Date) -> (UInt16, UInt16) {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let time = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
        let date = UInt16(max(0, (c.year ?? 1980) - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        return (time, date)
    }
}

private extension Data {
    mutating func u16(_ v: UInt16) { var x = v.littleEndian; Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { var x = v.littleEndian; Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) } }
}
