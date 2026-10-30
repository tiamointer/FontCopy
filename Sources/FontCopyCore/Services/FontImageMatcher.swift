import CoreGraphics
import CoreText
import Foundation
import Vision

/// 图里认出的一个字。box 是 Vision 的归一化坐标（原点左下）。
public struct RecognizedCharacter: Hashable, Sendable {
    public let character: Character
    public let box: CGRect

    public init(character: Character, box: CGRect) {
        self.character = character
        self.box = box
    }
}

/// 图里认出的一行字。海报这类图有好几行，让人点行选范围。
public struct RecognizedLine: Sendable {
    public let box: CGRect
    public let characters: [RecognizedCharacter]
}

/// 从图里切出来、归一化好的一个字形，用来和库里字体比对。
public struct FontImageTarget: Sendable {
    public let character: Character
    let mask: GlyphMask
}

public struct FontImageMatch: Identifiable, Sendable {
    public var id: UUID { font.id }
    public let font: FontItem
    /// 平均倒角距离（像素），越小越像。
    public let score: Double
}

/// 以图找字：Vision 认字 → 每个字切出来二值化 → 用库里每个字体写同样的字 → 比形状。
/// 形状差异用对称倒角距离：两边的墨迹像素互相找最近的墨迹，取平均距离。
public enum FontImageMatcher {
    static let side = 64
    static let renderSize: CGFloat = 128

    public static func recognize(_ image: CGImage) throws -> [RecognizedCharacter] {
        try recognizeLines(image).flatMap(\.characters)
    }

    public static func recognizeLines(_ image: CGImage) throws -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "zh-Hant"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])

        var lines: [RecognizedLine] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string
            var characters: [RecognizedCharacter] = []
            for index in text.indices {
                let character = text[index]
                guard !character.isWhitespace, !character.isPunctuation, !character.isSymbol else { continue }
                guard let box = try? candidate.boundingBox(for: index..<text.index(after: index)) else { continue }
                characters.append(RecognizedCharacter(character: character, box: box.boundingBox))
            }
            if !characters.isEmpty {
                lines.append(RecognizedLine(box: observation.boundingBox, characters: characters))
            }
        }
        return lines
    }

    /// 认不出字时的退路（手写、太小）：按墨迹范围沿长边切成 count 份，
    /// 切口挪到附近墨迹最少的那一列/行。返回 Vision 同款归一化坐标。
    public static func evenBoxes(in image: CGImage, count: Int) -> [CGRect] {
        guard count > 0, let gray = GrayImage(image) else { return [] }
        let threshold = GrayImage.otsu(gray.pixels)
        var ink = gray.pixels.map { $0 < threshold }
        if ink.filter({ $0 }).count * 2 > ink.count { ink = ink.map { !$0 } }

        let (w, h) = (gray.width, gray.height)
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where ink[y * w + x] {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX else { return [] }

        let horizontal = maxX - minX >= maxY - minY
        let (lo, hi) = horizontal ? (minX, maxX + 1) : (minY, maxY + 1)
        var profile = [Int](repeating: 0, count: hi - lo)
        for y in minY...maxY {
            for x in minX...maxX where ink[y * w + x] {
                profile[(horizontal ? x : y) - lo] += 1
            }
        }
        let cell = Double(hi - lo) / Double(count)
        var cuts = [lo]
        for i in 1..<max(count, 1) {
            let ideal = Int(Double(lo) + cell * Double(i))
            let reach = max(1, Int(cell * 0.25))
            let candidates = max(lo + 1, ideal - reach)...min(hi - 1, ideal + reach)
            cuts.append(candidates.min { profile[$0 - lo] < profile[$1 - lo] } ?? ideal)
        }
        cuts.append(hi)

        return zip(cuts, cuts.dropFirst()).map { a, b in
            let pixelRect = horizontal
                ? CGRect(x: a, y: minY, width: b - a, height: maxY - minY + 1)
                : CGRect(x: minX, y: a, width: maxX - minX + 1, height: b - a)
            return CGRect(
                x: pixelRect.minX / Double(w),
                y: 1 - pixelRect.maxY / Double(h),
                width: pixelRect.width / Double(w),
                height: pixelRect.height / Double(h)
            )
        }
    }

    public static func targets(from image: CGImage, characters: [RecognizedCharacter]) -> [FontImageTarget] {
        guard let gray = GrayImage(image) else { return [] }
        return characters.compactMap { item in
            guard let mask = gray.inkMask(in: item.box) else { return nil }
            return FontImageTarget(character: item.character, mask: mask)
        }
    }

    /// 只比对写得出全部目标字的字体；字形为空（登记了字但没画）的也算写不出。
    public static func rank(
        targets: [FontImageTarget],
        fonts: [FontItem],
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) -> [FontImageMatch] {
        guard !targets.isEmpty else { return [] }
        let distances = targets.map { $0.mask.distanceTransform() }

        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var matches: [FontImageMatch] = []
            var done = 0
        }
        let box = Box()

        fonts.withUnsafeBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: buffer.count) { index in
                let font = buffer[index]
                var total = 0.0
                var complete = true
                if let ctFont = makeFont(font) {
                    for (target, targetDistance) in zip(targets, distances) {
                        guard let mask = renderMask(target.character, font: ctFont) else {
                            complete = false
                            break
                        }
                        total += (target.mask.meanDistance(to: mask.distanceTransform())
                                  + mask.meanDistance(to: targetDistance)) / 2
                    }
                } else {
                    complete = false
                }

                box.lock.lock()
                if complete {
                    box.matches.append(FontImageMatch(font: font, score: total / Double(targets.count)))
                }
                box.done += 1
                let done = box.done
                box.lock.unlock()
                progress?(done, buffer.count)
            }
        }
        return box.matches.sorted { $0.score < $1.score }
    }

    /// 用某个字体把一行字画成图，给结果列表做预览。
    public static func renderLine(_ text: String, font: FontItem, height: CGFloat) -> CGImage? {
        guard let ctFont = makeFont(font, size: height * 0.8) else { return nil }
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): ctFont,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        let width = max(1, Int(ceil(CTLineGetTypographicBounds(line, nil, nil, nil))))
        guard let context = CGContext(
            data: nil, width: width, height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: Int(height)))
        context.setFillColor(gray: 0, alpha: 1)
        context.textPosition = CGPoint(x: 0, y: height * 0.2)
        CTLineDraw(line, context)
        return context.makeImage()
    }

    static func makeFont(_ font: FontItem, size: CGFloat = renderSize) -> CTFont? {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(font.sourceURL as CFURL) as? [CTFontDescriptor] else {
            return nil
        }
        let descriptor = descriptors.first {
            FontMetadataReader.stringAttribute($0, key: kCTFontNameAttribute) == font.postScriptName
        } ?? descriptors.first
        return descriptor.map { CTFontCreateWithFontDescriptor($0, size, nil) }
    }

    static func renderMask(_ character: Character, font: CTFont) -> GlyphMask? {
        let utf16 = Array(String(character).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        guard CTFontGetGlyphsForCharacters(font, utf16, &glyphs, utf16.count), glyphs[0] != 0 else { return nil }
        var glyph = glyphs[0]
        let bounds = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, nil, 1)
        guard bounds.width > 1, bounds.height > 1 else { return nil }

        let pad: CGFloat = 4
        let width = Int(ceil(bounds.width + pad * 2))
        let height = Int(ceil(bounds.height + pad * 2))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: 0, alpha: 1)
        var position = CGPoint(x: pad - bounds.minX, y: pad - bounds.minY)
        CTFontDrawGlyphs(font, &glyph, &position, 1, context)

        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height)
        var ink = [Bool](repeating: false, count: width * height)
        for i in 0..<(width * height) { ink[i] = pixels[i] < 128 }
        return GlyphMask.normalized(ink: ink, width: width, height: height)
    }
}

/// side × side 的墨迹图，字的外框缩放到撑满、保持长宽比、居中。
struct GlyphMask: Sendable {
    let bits: [Bool]

    static func normalized(ink: [Bool], width: Int, height: Int) -> GlyphMask? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where ink[y * width + x] {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }

        let side = FontImageMatcher.side
        let boxWidth = maxX - minX + 1
        let boxHeight = maxY - minY + 1
        let scale = Double(side - 4) / Double(max(boxWidth, boxHeight))
        let offsetX = (Double(side) - Double(boxWidth) * scale) / 2
        let offsetY = (Double(side) - Double(boxHeight) * scale) / 2
        var bits = [Bool](repeating: false, count: side * side)

        // 正向映射保住缩小时的细笔画，反向映射填满放大时的空隙
        for y in minY...maxY {
            for x in minX...maxX where ink[y * width + x] {
                let dx = min(side - 1, Int(Double(x - minX) * scale + offsetX))
                let dy = min(side - 1, Int(Double(y - minY) * scale + offsetY))
                bits[dy * side + dx] = true
            }
        }
        for dy in 0..<side {
            for dx in 0..<side {
                let sx = Int((Double(dx) + 0.5 - offsetX) / scale) + minX
                let sy = Int((Double(dy) + 0.5 - offsetY) / scale) + minY
                if sx >= minX, sx <= maxX, sy >= minY, sy <= maxY, ink[sy * width + sx] {
                    bits[dy * side + dx] = true
                }
            }
        }
        return GlyphMask(bits: bits)
    }

    /// 3-4 倒角距离变换：每个像素到最近墨迹的距离（单位约等于像素）。
    func distanceTransform() -> [Double] {
        let side = FontImageMatcher.side
        let far = 1_000_000
        var d = bits.map { $0 ? 0 : far }
        for y in 0..<side {
            for x in 0..<side {
                var v = d[y * side + x]
                if x > 0 { v = min(v, d[y * side + x - 1] + 3) }
                if y > 0 {
                    v = min(v, d[(y - 1) * side + x] + 3)
                    if x > 0 { v = min(v, d[(y - 1) * side + x - 1] + 4) }
                    if x < side - 1 { v = min(v, d[(y - 1) * side + x + 1] + 4) }
                }
                d[y * side + x] = v
            }
        }
        for y in stride(from: side - 1, through: 0, by: -1) {
            for x in stride(from: side - 1, through: 0, by: -1) {
                var v = d[y * side + x]
                if x < side - 1 { v = min(v, d[y * side + x + 1] + 3) }
                if y < side - 1 {
                    v = min(v, d[(y + 1) * side + x] + 3)
                    if x < side - 1 { v = min(v, d[(y + 1) * side + x + 1] + 4) }
                    if x > 0 { v = min(v, d[(y + 1) * side + x - 1] + 4) }
                }
                d[y * side + x] = v
            }
        }
        return d.map { Double($0) / 3 }
    }

    /// 本字形每个墨迹像素到另一字形最近墨迹的平均距离。
    func meanDistance(to otherDistance: [Double]) -> Double {
        var sum = 0.0
        var count = 0
        for i in bits.indices where bits[i] {
            sum += otherDistance[i]
            count += 1
        }
        return count == 0 ? .infinity : sum / Double(count)
    }
}

/// 整张图转灰度，按 Vision 的字框切字、二值化。
struct GrayImage {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    init?(_ image: CGImage) {
        width = image.width
        height = image.height
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        pixels = Array(UnsafeBufferPointer(start: data.bindMemory(to: UInt8.self, capacity: width * height),
                                           count: width * height))
    }

    func inkMask(in normalizedBox: CGRect) -> GlyphMask? {
        // Vision 的字框常常贴着笔画切，四周放宽 12%
        let box = normalizedBox.insetBy(dx: -normalizedBox.width * 0.12, dy: -normalizedBox.height * 0.12)
        // 位图第 0 行是图的顶部，Vision 原点在左下
        let x0 = max(0, Int(box.minX * Double(width)))
        let x1 = min(width, Int(ceil(box.maxX * Double(width))))
        let y0 = max(0, Int((1 - box.maxY) * Double(height)))
        let y1 = min(height, Int(ceil((1 - box.minY) * Double(height))))
        let cropWidth = x1 - x0
        let cropHeight = y1 - y0
        guard cropWidth > 2, cropHeight > 2 else { return nil }

        var crop = [UInt8](repeating: 0, count: cropWidth * cropHeight)
        for y in 0..<cropHeight {
            for x in 0..<cropWidth {
                crop[y * cropWidth + x] = pixels[(y0 + y) * width + x0 + x]
            }
        }
        let threshold = Self.otsu(crop)
        var ink = crop.map { $0 < threshold }
        // 字一般占不到框的一半；暗的那边占多数说明是深底浅字，反过来
        if ink.filter({ $0 }).count * 2 > ink.count {
            ink = ink.map { !$0 }
        }
        // 放宽后的框会带进邻字的笔画：只留碰到原框中间区域的连通块
        let core = CGRect(
            x: (normalizedBox.minX + normalizedBox.width * 0.15) * Double(width) - Double(x0),
            y: (1 - normalizedBox.maxY + normalizedBox.height * 0.15) * Double(height) - Double(y0),
            width: normalizedBox.width * 0.7 * Double(width),
            height: normalizedBox.height * 0.7 * Double(height)
        )
        ink = Self.keepComponents(ink, width: cropWidth, height: cropHeight, touching: core)
        return GlyphMask.normalized(ink: ink, width: cropWidth, height: cropHeight)
    }

    static func keepComponents(_ ink: [Bool], width: Int, height: Int, touching core: CGRect) -> [Bool] {
        var kept = [Bool](repeating: false, count: ink.count)
        var seen = [Bool](repeating: false, count: ink.count)
        for start in ink.indices where ink[start] && !seen[start] {
            var component: [Int] = []
            var stack = [start]
            seen[start] = true
            var touches = false
            while let i = stack.popLast() {
                component.append(i)
                let x = i % width, y = i / width
                if core.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) { touches = true }
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                where nx >= 0 && nx < width && ny >= 0 && ny < height {
                    let n = ny * width + nx
                    if ink[n] && !seen[n] {
                        seen[n] = true
                        stack.append(n)
                    }
                }
            }
            if touches {
                for i in component { kept[i] = true }
            }
        }
        return kept
    }

    static func otsu(_ values: [UInt8]) -> UInt8 {
        var histogram = [Int](repeating: 0, count: 256)
        for v in values { histogram[Int(v)] += 1 }
        let total = Double(values.count)
        let sumAll = histogram.enumerated().reduce(0.0) { $0 + Double($1.offset * $1.element) }
        var sumBackground = 0.0
        var weightBackground = 0.0
        var best = 0.0
        var threshold = 128
        for t in 0..<256 {
            weightBackground += Double(histogram[t])
            guard weightBackground > 0 else { continue }
            let weightForeground = total - weightBackground
            guard weightForeground > 0 else { break }
            sumBackground += Double(t * histogram[t])
            let meanBackground = sumBackground / weightBackground
            let meanForeground = (sumAll - sumBackground) / weightForeground
            let between = weightBackground * weightForeground * pow(meanBackground - meanForeground, 2)
            if between > best {
                best = between
                threshold = t + 1
            }
        }
        return UInt8(min(threshold, 255))
    }
}
