import Foundation
import AppKit

/// 세션 → PowerPoint(.pptx). 외부 라이브러리 없이 OOXML을 직접 쓴다.
/// 규칙: 사진 한 장(같은 앵커 문장의 여러 장은 함께) = 슬라이드 하나, 그 사진의 앵커 문장부터 다음 사진 앵커 전까지가 그 슬라이드의 텍스트.
/// 사진이 없는 구간(또는 사진이 전혀 없는 세션)은 텍스트만. 문장이 많으면 같은 사진을 유지한 채 이어지는 슬라이드로 나눈다.
@MainActor
enum PptxExporter {
    struct Options {
        var includeEnglish = true
        var maxSentencesPerSlide = 6           // 사진 슬라이드 (텍스트 전용은 ×1.5)
        var photosPerSlide = 3
    }

    enum ExportError: LocalizedError {
        case writeFailed(String)
        var errorDescription: String? { if case .writeFailed(let m) = self { return "pptx 저장 실패: \(m)" }; return nil }
    }

    // 16:9, EMU (914400 = 1인치)
    private static let slideW = 12_192_000, slideH = 6_858_000
    private static let margin = 457_200
    private static let photoColW = 6_858_000
    private static let gap = 457_200
    private static let contentH = 5_486_400          // 6인치
    private static let footerY = 6_172_200

    /// 슬라이드 하나의 내용
    private struct Slide {
        var photos: [PhotoMatch]
        var lines: [TranscriptLine]
        var index: Int
        var continued: Bool
    }

    /// 파일 생성. 성공 시 슬라이드 수 반환.
    @discardableResult
    static func export(detail: SessionDetail, to url: URL, options: Options = Options()) throws -> Int {
        let slides = plan(detail: detail, options: options)
        var zip = ZipWriter()
        var parts: [(String, String)] = []        // (경로, XML) — [Content_Types].xml 을 첫 항목으로 넣기 위해 모아 둠
        func write(_ path: String, _ s: String) throws { parts.append((path, s)) }

        // 미디어: 사진 파일 (같은 사진이 여러 슬라이드에 쓰여도 한 번만)
        var mediaIndex: [String: Int] = [:]
        var media: [(String, Data)] = []
        for s in slides {
            for p in s.photos where mediaIndex[p.file] == nil {
                guard let d = try? Data(contentsOf: detail.summary.url.appendingPathComponent(p.file)) else { continue }
                mediaIndex[p.file] = media.count + 1
                media.append(("ppt/media/image\(media.count + 1).jpg", d))
            }
        }
        let mediaCount = media.count

        // 슬라이드 XML
        let total = slides.count + 1
        try write("ppt/slides/slide1.xml", titleSlide(detail: detail, slideCount: slides.count))
        try write("ppt/slides/_rels/slide1.xml.rels", slideRels(media: []))
        for (i, s) in slides.enumerated() {
            let n = i + 2
            let ids = s.photos.compactMap { mediaIndex[$0.file] }
            try write("ppt/slides/slide\(n).xml", contentSlide(s, detail: detail, media: ids, options: options, number: n - 1, of: slides.count))
            try write("ppt/slides/_rels/slide\(n).xml.rels", slideRels(media: ids))
        }

        // 패키지 뼈대
        try write("[Content_Types].xml", contentTypes(slideCount: total, mediaCount: mediaCount))
        try write("_rels/.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/></Relationships>
        """)
        try write("docProps/core.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:title>\(esc(detail.summary.title))</dc:title><dc:creator>LiveSubtitle</dc:creator><dcterms:created xsi:type="dcterms:W3CDTF">\(utc(Date()))</dcterms:created><dcterms:modified xsi:type="dcterms:W3CDTF">\(utc(Date()))</dcterms:modified></cp:coreProperties>
        """)
        try write("docProps/app.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"><Application>LiveSubtitle</Application><Slides>\(total)</Slides></Properties>
        """)
        try write("ppt/presentation.xml", presentation(slideCount: total))
        try write("ppt/_rels/presentation.xml.rels", presentationRels(slideCount: total))
        try write("ppt/presProps.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:presentationPr xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"/>
        """)
        try write("ppt/viewProps.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:viewPr xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:normalViewPr><p:restoredLeft sz="15620"/><p:restoredTop sz="94660"/></p:normalViewPr><p:gridSpacing cx="72008" cy="72008"/></p:viewPr>
        """)
        try write("ppt/tableStyles.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <a:tblStyleLst xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" def="{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}"/>
        """)
        try write("ppt/slideMasters/slideMaster1.xml", slideMaster())
        try write("ppt/slideMasters/_rels/slideMaster1.xml.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme1.xml"/></Relationships>
        """)
        try write("ppt/slideLayouts/slideLayout1.xml", slideLayout())
        try write("ppt/slideLayouts/_rels/slideLayout1.xml.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/></Relationships>
        """)
        try write("ppt/theme/theme1.xml", theme())

        // 조립: [Content_Types].xml → 나머지 XML → 미디어
        if let ct = parts.first(where: { $0.0 == "[Content_Types].xml" }) { zip.add(ct.0, ct.1) }
        for (path, xml) in parts where path != "[Content_Types].xml" { zip.add(path, xml) }
        for (path, d) in media { zip.add(path, d) }          // 줄어들면 deflate, 아니면 stored
        do { try zip.finish().write(to: url, options: .atomic) }
        catch { throw ExportError.writeFailed(error.localizedDescription) }
        FileLog.write("pptx exported: \(url.path) slides=\(total) media=\(mediaCount)")
        return total
    }

    // MARK: 슬라이드 계획

    private static func plan(detail: SessionDetail, options: Options) -> [Slide] {
        let groups = PhotoImporter.groups(photos: detail.photos, segments: detail.segments)
        var out: [Slide] = []
        for g in groups {
            let photoPages = g.photos.isEmpty ? [[]] : stride(from: 0, to: g.photos.count, by: options.photosPerSlide).map { Array(g.photos[$0..<min($0 + options.photosPerSlide, g.photos.count)]) }
            let per = g.photos.isEmpty ? Int(Double(options.maxSentencesPerSlide) * 1.5) : options.maxSentencesPerSlide
            let textPages: [[TranscriptLine]] = g.segments.isEmpty ? [[]] : stride(from: 0, to: g.segments.count, by: per).map { Array(g.segments[$0..<min($0 + per, g.segments.count)]) }
            // 첫 사진 묶음 + 텍스트 페이지들(같은 사진 유지), 사진이 4장 이상이면 나머지 묶음은 사진만
            for (k, t) in textPages.enumerated() {
                out.append(Slide(photos: photoPages[0], lines: t, index: out.count, continued: k > 0))
            }
            for extra in photoPages.dropFirst() {
                out.append(Slide(photos: extra, lines: [], index: out.count, continued: true))
            }
        }
        return out
    }

    // MARK: 슬라이드 XML

    private static let nsDecl = "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\""

    private static func titleSlide(detail: SessionDetail, slideCount: Int) -> String {
        let s = detail.summary
        let sub = "\(SessionRecorder.fullStamp.string(from: s.startedAt))" + (s.endedAt.map { " → \(SessionRecorder.timeOnly.string(from: $0))" } ?? "")
            + " · \(SessionRecorder.clock(s.durationSeconds)) · 문장 \(s.sentences) · 단어 \(s.words) · 사진 \(detail.photos.filter { !$0.excluded }.count)장 · 슬라이드 \(slideCount)"
        let paras = [para(esc(s.title), size: 4000, bold: true, color: "1F1F1F", align: "ctr"),
                     para(esc(sub), size: 1600, color: "6B6B6B", align: "ctr"),
                     para(esc("인식 \(s.engine) · Apple 기기 내 번역 · LiveSubtitle"), size: 1200, color: "9A9A9A", align: "ctr")]
        let body = textBox(id: 2, name: "Title", x: margin, y: 2_286_000, w: slideW - 2 * margin, h: 2_286_000, paras: paras, anchor: "ctr")
        return slideXML(body)
    }

    private static func contentSlide(_ s: Slide, detail: SessionDetail, media: [Int], options: Options, number: Int, of total: Int) -> String {
        var shapes: [String] = []
        var id = 2
        let hasPhoto = !s.photos.isEmpty
        // 사진: 왼쪽 열을 세로로 나눠 비율 유지
        if hasPhoto {
            let photos = Array(s.photos.prefix(media.count))     // 파일을 못 읽은 사진은 제외
            let n = max(1, photos.count)
            let cellH = (contentH - gap / 2 * (n - 1)) / n
            for (i, p) in photos.enumerated() {
                let boxX = margin, boxY = margin + i * (cellH + gap / 2)
                let scale = min(Double(photoColW) / Double(max(1, p.width)), Double(cellH) / Double(max(1, p.height)))
                let w = Int(Double(p.width) * scale), h = Int(Double(p.height) * scale)
                let x = boxX + (photoColW - w) / 2, y = boxY + (cellH - h) / 2
                shapes.append(picture(id: id, rId: "rId\(i + 2)", name: "Photo \(i + 1)", x: x, y: y, w: w, h: h,
                                      descr: "\(SessionRecorder.fullStamp.string(from: p.capturedAt)) 촬영"))
                id += 1
            }
        }
        // 텍스트
        let textX = hasPhoto ? margin + photoColW + gap : margin
        let textW = hasPhoto ? slideW - textX - margin : slideW - 2 * margin
        var paras: [String] = []
        let koSize = hasPhoto ? 1500 : 1800
        let enSize = hasPhoto ? 1100 : 1300
        if s.continued && !s.lines.isEmpty { paras.append(para("(이어서)", size: 1000, color: "9A9A9A")) }
        for l in s.lines {
            let main = l.target.isEmpty ? l.source : l.target
            paras.append(para(esc(main), size: koSize, color: "1F1F1F", spaceBefore: 600))
            if options.includeEnglish && !l.target.isEmpty && l.source != l.target {
                paras.append(para(esc(l.source), size: enSize, color: "7A7A7A"))
            }
        }
        if s.lines.isEmpty { paras.append(para(hasPhoto ? "(이 사진 구간에 확정된 문장 없음)" : "", size: 1200, color: "9A9A9A")) }
        shapes.append(textBox(id: id, name: "Body", x: textX, y: margin, w: textW, h: contentH, paras: paras, anchor: "t", autofit: true))
        id += 1
        // 바닥글: 슬라이드 번호 · 시각 범위
        var foot = "\(number) / \(total)"
        if let f = s.lines.first, let l = s.lines.last {
            foot += " · \(SessionRecorder.timeOnly.string(from: f.startedAt)) – \(SessionRecorder.timeOnly.string(from: l.endedAt))"
        } else if let p = s.photos.first {
            foot += " · \(SessionRecorder.timeOnly.string(from: p.capturedAt)) 촬영"
        }
        foot += " · \(detail.summary.title)"
        shapes.append(textBox(id: id, name: "Footer", x: margin, y: footerY, w: slideW - 2 * margin, h: 320_040,
                              paras: [para(esc(foot), size: 900, color: "9A9A9A", align: "r")], anchor: "b"))
        return slideXML(shapes.joined())
    }

    private static func slideXML(_ shapes: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sld \(nsDecl)><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>\(shapes)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>
        """
    }

    private static func textBox(id: Int, name: String, x: Int, y: Int, w: Int, h: Int, paras: [String], anchor: String, autofit: Bool = false) -> String {
        """
        <p:sp><p:nvSpPr><p:cNvPr id="\(id)" name="\(esc(name))"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x="\(x)" y="\(y)"/><a:ext cx="\(w)" cy="\(h)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/></p:spPr><p:txBody><a:bodyPr wrap="square" lIns="91440" tIns="45720" rIns="91440" bIns="45720" rtlCol="0" anchor="\(anchor)">\(autofit ? "<a:normAutofit/>" : "<a:noAutofit/>")</a:bodyPr><a:lstStyle/>\(paras.joined())</p:txBody></p:sp>
        """
    }

    private static func picture(id: Int, rId: String, name: String, x: Int, y: Int, w: Int, h: Int, descr: String) -> String {
        """
        <p:pic><p:nvPicPr><p:cNvPr id="\(id)" name="\(esc(name))" descr="\(esc(descr))"/><p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed="\(rId)"/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr><a:xfrm><a:off x="\(x)" y="\(y)"/><a:ext cx="\(w)" cy="\(h)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic>
        """
    }

    /// 문단 하나. size는 1/100 pt.
    private static func para(_ escapedText: String, size: Int, bold: Bool = false, color: String, align: String = "l", spaceBefore: Int = 0) -> String {
        let pPr = "<a:pPr algn=\"\(align)\">" + (spaceBefore > 0 ? "<a:spcBef><a:spcPts val=\"\(spaceBefore)\"/></a:spcBef>" : "") + "</a:pPr>"
        let rPr = "<a:rPr lang=\"ko-KR\" altLang=\"en-US\" sz=\"\(size)\"\(bold ? " b=\"1\"" : "") dirty=\"0\"><a:solidFill><a:srgbClr val=\"\(color)\"/></a:solidFill><a:latin typeface=\"+mn-lt\"/><a:ea typeface=\"+mn-ea\"/></a:rPr>"
        return "<a:p>\(pPr)<a:r>\(rPr)<a:t>\(escapedText)</a:t></a:r></a:p>"
    }

    private static func slideRels(media: [Int]) -> String {
        var rels = "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/>"
        for (i, m) in media.enumerated() {
            rels += "<Relationship Id=\"rId\(i + 2)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"../media/image\(m).jpg\"/>"
        }
        return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(rels)</Relationships>"
    }

    // MARK: 패키지 뼈대

    private static func contentTypes(slideCount: Int, mediaCount: Int) -> String {
        var s = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
        s += "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Default Extension=\"jpg\" ContentType=\"image/jpeg\"/>"
        s += "<Override PartName=\"/ppt/presentation.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml\"/>"
        s += "<Override PartName=\"/ppt/presProps.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.presProps+xml\"/>"
        s += "<Override PartName=\"/ppt/viewProps.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.viewProps+xml\"/>"
        s += "<Override PartName=\"/ppt/tableStyles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.tableStyles+xml\"/>"
        s += "<Override PartName=\"/ppt/slideMasters/slideMaster1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml\"/>"
        s += "<Override PartName=\"/ppt/slideLayouts/slideLayout1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml\"/>"
        s += "<Override PartName=\"/ppt/theme/theme1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.theme+xml\"/>"
        for i in 1...slideCount {
            s += "<Override PartName=\"/ppt/slides/slide\(i).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>"
        }
        s += "<Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/>"
        s += "<Override PartName=\"/docProps/app.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.extended-properties+xml\"/>"
        return s + "</Types>"
    }

    private static func presentation(slideCount: Int) -> String {
        var ids = ""
        for i in 1...slideCount { ids += "<p:sldId id=\"\(255 + i)\" r:id=\"rId\(i + 1)\"/>" }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:presentation \(nsDecl) saveSubsetFonts="1"><p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst><p:sldIdLst>\(ids)</p:sldIdLst><p:sldSz cx="\(slideW)" cy="\(slideH)"/><p:notesSz cx="6858000" cy="9144000"/><p:defaultTextStyle><a:defPPr><a:defRPr lang="ko-KR"/></a:defPPr></p:defaultTextStyle></p:presentation>
        """
    }

    private static func presentationRels(slideCount: Int) -> String {
        var rels = "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster\" Target=\"slideMasters/slideMaster1.xml\"/>"
        for i in 1...slideCount {
            rels += "<Relationship Id=\"rId\(i + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide\" Target=\"slides/slide\(i).xml\"/>"
        }
        let n = slideCount + 2
        rels += "<Relationship Id=\"rId\(n)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/presProps\" Target=\"presProps.xml\"/>"
        rels += "<Relationship Id=\"rId\(n + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/viewProps\" Target=\"viewProps.xml\"/>"
        rels += "<Relationship Id=\"rId\(n + 2)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme\" Target=\"theme/theme1.xml\"/>"
        rels += "<Relationship Id=\"rId\(n + 3)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/tableStyles\" Target=\"tableStyles.xml\"/>"
        return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(rels)</Relationships>"
    }

    private static func slideMaster() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sldMaster \(nsDecl)><p:cSld><p:bg><p:bgPr><a:solidFill><a:srgbClr val="FFFFFF"/></a:solidFill><a:effectLst/></p:bgPr></p:bg><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr></p:spTree></p:cSld><p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/><p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst><p:txStyles><p:titleStyle><a:lvl1pPr><a:defRPr sz="4000"/></a:lvl1pPr></p:titleStyle><p:bodyStyle><a:lvl1pPr><a:defRPr sz="1800"/></a:lvl1pPr></p:bodyStyle><p:otherStyle><a:lvl1pPr><a:defRPr sz="1800"/></a:lvl1pPr></p:otherStyle></p:txStyles></p:sldMaster>
        """
    }

    private static func slideLayout() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sldLayout \(nsDecl) type="blank" preserve="1"><p:cSld name="Blank"><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>
        """
    }

    private static func theme() -> String {
        let fill = "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>"
        let ln = "<a:ln w=\"9525\" cap=\"flat\" cmpd=\"sng\" algn=\"ctr\"><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill><a:prstDash val=\"solid\"/></a:ln>"
        let effect = "<a:effectStyle><a:effectLst/></a:effectStyle>"
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="LiveSubtitle"><a:themeElements><a:clrScheme name="LiveSubtitle"><a:dk1><a:srgbClr val="1F1F1F"/></a:dk1><a:lt1><a:srgbClr val="FFFFFF"/></a:lt1><a:dk2><a:srgbClr val="44546A"/></a:dk2><a:lt2><a:srgbClr val="E7E6E6"/></a:lt2><a:accent1><a:srgbClr val="2A78D6"/></a:accent1><a:accent2><a:srgbClr val="EB6834"/></a:accent2><a:accent3><a:srgbClr val="1BAF7A"/></a:accent3><a:accent4><a:srgbClr val="EDA100"/></a:accent4><a:accent5><a:srgbClr val="E87BA4"/></a:accent5><a:accent6><a:srgbClr val="4A3AA7"/></a:accent6><a:hlink><a:srgbClr val="0563C1"/></a:hlink><a:folHlink><a:srgbClr val="954F72"/></a:folHlink></a:clrScheme><a:fontScheme name="LiveSubtitle"><a:majorFont><a:latin typeface="Helvetica Neue"/><a:ea typeface="Apple SD Gothic Neo"/><a:cs typeface=""/></a:majorFont><a:minorFont><a:latin typeface="Helvetica Neue"/><a:ea typeface="Apple SD Gothic Neo"/><a:cs typeface=""/></a:minorFont></a:fontScheme><a:fmtScheme name="LiveSubtitle"><a:fillStyleLst>\(fill)\(fill)\(fill)</a:fillStyleLst><a:lnStyleLst>\(ln)\(ln)\(ln)</a:lnStyleLst><a:effectStyleLst>\(effect)\(effect)\(effect)</a:effectStyleLst><a:bgFillStyleLst>\(fill)\(fill)\(fill)</a:bgFillStyleLst></a:fmtScheme></a:themeElements><a:objectDefaults/><a:extraClrSchemeLst/></a:theme>
        """
    }

    // MARK: 유틸

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func utc(_ d: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; f.timeZone = TimeZone(identifier: "UTC"); return f.string(from: d)
    }
}
