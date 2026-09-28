import Foundation
import Photos
import AppKit

/// 세션 중 촬영한 사진 하나와 그 앵커 문장. 나중에 pptx로 만들 때 "사진 → 슬라이드, 앵커 문장부터 다음 사진의 앵커 전까지 → 그 슬라이드의 텍스트".
struct PhotoMatch: Codable, Identifiable, Equatable {
    var id: String { localIdentifier }
    let localIdentifier: String     // Photos 보관함 안의 식별자 (중복 가져오기 방지)
    let file: String                // photos/001.jpg  (최대 2048px JPEG)
    let thumb: String               // photos/thumbs/001.jpg  (최대 320px)
    let capturedAt: Date            // 촬영 시각 (Photos creationDate)
    let width: Int
    let height: Int
    var segmentIndex: Int?          // 앵커 문장 index (transcript.json) — 촬영 시각에 가장 가까운 문장
    var distanceSeconds: Double     // 앵커 문장 발화 구간과의 거리 (0 = 그 문장을 말하는 동안 촬영)
    var excluded: Bool              // 사용자가 제외한 사진
}

/// photos.json
struct PhotosDocument: Codable {
    var format = "livesubtitle-photos/1"
    var sessionId: String
    var lagSeconds: Double          // 매칭에 쓴 인식 지연 (문장 시각을 이만큼 앞당겨 발화 시각으로 봄)
    var importedAt: Date
    var photos: [PhotoMatch]
}

/// Photos 보관함에서 세션 시간 범위의 사진을 가져와 문장과 맞춘다.
/// 아이폰 사진은 iCloud 사진이 켜져 있으면 맥 Photos에 자동으로 들어오므로 그대로 잡힌다.
@MainActor
final class PhotoImporter: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var status = ""

    static let marginSeconds: TimeInterval = 5 * 60      // 세션 앞뒤로 이만큼 더 찾음 (강연 시작 전 제목 슬라이드 등)
    static let maxPixels: CGFloat = 2048
    static let thumbPixels: CGFloat = 320

    // MARK: photos.json

    static func load(_ folder: URL) -> PhotosDocument? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("photos.json")) else { return nil }
        return try? SessionRecorder.decoder.decode(PhotosDocument.self, from: data)
    }

    static func save(_ doc: PhotosDocument, to folder: URL) {
        guard let data = try? SessionRecorder.encoder.encode(doc) else { return }
        try? data.write(to: folder.appendingPathComponent("photos.json"), options: .atomic)
    }

    /// 촬영 시각에 가장 가까운 문장. 문장 시각은 인식 지연만큼 앞당겨 실제 발화 시각으로 본다.
    static func anchor(for captured: Date, segments: [TranscriptLine], lag: Double) -> (index: Int?, distance: Double) {
        var best: (Int, Double)?
        for s in segments {
            let a = s.startedAt.addingTimeInterval(-lag), b = s.endedAt.addingTimeInterval(-lag)
            let d = captured < a ? a.timeIntervalSince(captured) : (captured > b ? captured.timeIntervalSince(b) : 0)
            if best == nil || d < best!.1 { best = (s.index, d) }
        }
        guard let best else { return (nil, 0) }
        return (best.0, best.1)
    }

    /// 사진 기준으로 문장을 묶는다 (pptx 슬라이드 미리보기): 첫 사진 앞의 문장은 텍스트만, 이후는 각 사진의 앵커부터 다음 사진 앵커 전까지.
    static func groups(photos: [PhotoMatch], segments: [TranscriptLine]) -> [(photos: [PhotoMatch], segments: [TranscriptLine])] {
        let usable = photos.filter { !$0.excluded && $0.segmentIndex != nil }.sorted { $0.capturedAt < $1.capturedAt }
        guard !usable.isEmpty else { return segments.isEmpty ? [] : [([], segments)] }
        // 같은 앵커의 사진은 한 슬라이드
        var anchors: [Int] = []
        var byAnchor: [Int: [PhotoMatch]] = [:]
        for p in usable {
            let i = p.segmentIndex!
            if byAnchor[i] == nil { anchors.append(i) }
            byAnchor[i, default: []].append(p)
        }
        anchors.sort()
        var out: [(photos: [PhotoMatch], segments: [TranscriptLine])] = []
        let before = segments.filter { $0.index < anchors[0] }
        if !before.isEmpty { out.append(([], before)) }
        for (k, a) in anchors.enumerated() {
            let end = k + 1 < anchors.count ? anchors[k + 1] : Int.max
            out.append((byAnchor[a] ?? [], segments.filter { $0.index >= a && $0.index < end }))
        }
        return out
    }

    // MARK: 가져오기

    enum ImportError: LocalizedError {
        case denied(PHAuthorizationStatus)
        var errorDescription: String? {
            switch self {
            case .denied(let s):
                return s == .denied || s == .restricted
                    ? "사진 보관함 접근이 거부됨 — 시스템 설정 > 개인정보 보호 및 보안 > 사진 > LiveSubtitle 켜기"
                    : "사진 보관함 접근 권한 없음 (\(s.rawValue))"
            }
        }
    }

    /// 세션 시간 범위(±5분)의 사진을 가져와 photos/ 에 JPEG로 복사하고 문장과 맞춘다. 이미 가져온 사진은 건너뛴다(사용자 조정 유지).
    func importPhotos(session: SessionSummary, segments: [TranscriptLine], lag: Double) async -> Result<PhotosDocument, Error> {
        busy = true
        defer { busy = false }
        status = "사진 보관함 권한 확인 중…"
        var auth = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if auth == .notDetermined { auth = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
        guard auth == .authorized || auth == .limited else {
            status = ImportError.denied(auth).localizedDescription
            return .failure(ImportError.denied(auth))
        }

        let start = session.startedAt.addingTimeInterval(-Self.marginSeconds)
        let end = (session.endedAt ?? Date()).addingTimeInterval(Self.marginSeconds)
        let folder = session.url
        var doc = Self.load(folder) ?? PhotosDocument(sessionId: session.id, lagSeconds: lag, importedAt: Date(), photos: [])
        let known = Set(doc.photos.map(\.localIdentifier))
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("photos/thumbs"), withIntermediateDirectories: true)

        status = "\(SessionRecorder.timeOnly.string(from: start)) ~ \(SessionRecorder.timeOnly.string(from: end)) 사진 찾는 중…"
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "mediaType == %d AND creationDate >= %@ AND creationDate <= %@",
                                     PHAssetMediaType.image.rawValue, start as NSDate, end as NSDate)
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let fetched = PHAsset.fetchAssets(with: opts)
        var assets: [PHAsset] = []
        fetched.enumerateObjects { a, _, _ in assets.append(a) }
        let fresh = assets.filter { !known.contains($0.localIdentifier) }
        FileLog.write("photos: \(assets.count) in range, \(fresh.count) new, session \(session.id)")

        var next = (doc.photos.map { Int($0.file.dropFirst("photos/".count).prefix(3)) ?? 0 }.max() ?? 0) + 1
        var added = 0, failed = 0
        for (n, asset) in fresh.enumerated() {
            status = "사진 복사 중… \(n + 1)/\(fresh.count)"
            guard let captured = asset.creationDate, let img = await Self.requestImage(asset) else { failed += 1; continue }
            let name = String(format: "%03d", next)
            let file = "photos/\(name).jpg", thumb = "photos/thumbs/\(name).jpg"
            guard let (data, w, h) = Self.jpeg(img, maxPx: Self.maxPixels), let (tdata, _, _) = Self.jpeg(img, maxPx: Self.thumbPixels) else { failed += 1; continue }
            do {
                try data.write(to: folder.appendingPathComponent(file), options: .atomic)
                try tdata.write(to: folder.appendingPathComponent(thumb), options: .atomic)
            } catch { failed += 1; FileLog.write("photo write failed: \(error)"); continue }
            let (idx, dist) = Self.anchor(for: captured, segments: segments, lag: lag)
            doc.photos.append(PhotoMatch(localIdentifier: asset.localIdentifier, file: file, thumb: thumb, capturedAt: captured,
                                         width: w, height: h, segmentIndex: idx, distanceSeconds: dist, excluded: false))
            next += 1
            added += 1
        }
        doc.photos.sort { $0.capturedAt < $1.capturedAt }
        doc.lagSeconds = lag
        doc.importedAt = Date()
        Self.save(doc, to: folder)
        status = "사진 \(assets.count)장 중 \(added)장 새로 가져옴" + (failed > 0 ? ", \(failed)장 실패" : "") + " · 총 \(doc.photos.count)장"
        FileLog.write("photos imported: +\(added) failed=\(failed) total=\(doc.photos.count)")
        return .success(doc)
    }

    /// 원본을 최대 2048px로 요청 (iCloud에만 있는 사진은 내려받음). 고품질 한 번만 전달되도록 설정.
    private static func requestImage(_ asset: PHAsset) async -> NSImage? {
        await withCheckedContinuation { cont in
            let o = PHImageRequestOptions()
            o.isNetworkAccessAllowed = true
            o.deliveryMode = .highQualityFormat
            o.resizeMode = .exact
            o.isSynchronous = false
            var done = false
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: maxPixels, height: maxPixels), contentMode: .aspectFit, options: o) { img, info in
                if done { return }
                if let degraded = info?[PHImageResultIsDegradedKey] as? Bool, degraded { return }
                done = true
                cont.resume(returning: img)
            }
        }
    }

    /// NSImage → JPEG (긴 변을 maxPx 이하로)
    static func jpeg(_ img: NSImage, maxPx: CGFloat) -> (Data, Int, Int)? {
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = cg.width, h = cg.height
        let scale = min(1, maxPx / CGFloat(max(w, h)))
        let tw = max(1, Int(CGFloat(w) * scale)), th = max(1, Int(CGFloat(h) * scale))
        guard let ctx = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: tw, height: th))
        guard let out = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: out)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return nil }
        return (data, tw, th)
    }
}
