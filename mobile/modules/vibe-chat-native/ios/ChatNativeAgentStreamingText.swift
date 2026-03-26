import UIKit

private let chatNativeAgentBoldRegex = try! NSRegularExpression(pattern: "\\*\\*(.+?)\\*\\*")
private let chatNativeAgentMarkdownLinkRegex = try! NSRegularExpression(pattern: "\\[([^\\]]+)\\]\\((https?://[^)]+)\\)")
private let chatNativeAgentInlineCodeRegex = try! NSRegularExpression(pattern: "`([^`]+)`")

protocol ChatNativeStreamingTextLabelDelegate: AnyObject {
  func streamingTextLabel(_ label: ChatNativeStreamingTextLabel, didTap url: URL)
}

enum ChatNativeAgentTextRenderer {
  static func isRTL(_ text: String) -> Bool {
    text.range(of: "[\\u0600-\\u06FF]", options: .regularExpression) != nil
  }

  static func makeAttributedText(
    text: String,
    font: UIFont,
    textColor: UIColor,
    lineHeight: CGFloat? = nil
  ) -> NSAttributedString {
    let isRtl = isRTL(text)
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.alignment = isRtl ? .right : .natural
    paragraphStyle.baseWritingDirection = isRtl ? .rightToLeft : .leftToRight
    paragraphStyle.lineBreakMode = .byWordWrapping
    if let lineHeight {
      paragraphStyle.minimumLineHeight = lineHeight
      paragraphStyle.maximumLineHeight = lineHeight
    }

    var baseAttrs: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: textColor,
      .paragraphStyle: paragraphStyle,
    ]
    if let lineHeight {
      baseAttrs[.baselineOffset] = (lineHeight - font.lineHeight) * 0.25
    }

    // Split text into fenced code blocks and regular text blocks.
    let blocks = splitFencedCodeBlocks(text)

    guard blocks.count > 1 else {
      // Fast path: no code fences — process lines directly.
      if case .normalText(let t) = blocks.first ?? .normalText(text) {
        return applyLineMarkdown(t, baseAttrs: baseAttrs, font: font, textColor: textColor)
      }
      return applyLineMarkdown(text, baseAttrs: baseAttrs, font: font, textColor: textColor)
    }

    let result = NSMutableAttributedString()
    for (i, block) in blocks.enumerated() {
      if i > 0 { result.append(NSAttributedString(string: "\n", attributes: baseAttrs)) }
      switch block {
      case .normalText(let t):
        result.append(applyLineMarkdown(t, baseAttrs: baseAttrs, font: font, textColor: textColor))
      case .codeBlock(let code):
        result.append(renderCodeBlock(code, baseFont: font, textColor: textColor))
      }
    }
    return result
  }

  // MARK: - Block-level parsing

  private enum MarkdownBlock {
    case normalText(String)
    case codeBlock(String)
  }

  /// Splits raw markdown text into alternating normalText / codeBlock segments
  /// by detecting fenced code blocks (``` ... ```).
  private static func splitFencedCodeBlocks(_ text: String) -> [MarkdownBlock] {
    var blocks: [MarkdownBlock] = []
    var normalLines: [String] = []
    var codeLines: [String] = []
    var inCodeBlock = false

    for line in text.components(separatedBy: "\n") {
      if line.hasPrefix("```") {
        if inCodeBlock {
          // End of fenced code block.
          let codeText = codeLines.joined(separator: "\n")
          if !codeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append(.codeBlock(codeText))
          }
          codeLines = []
          inCodeBlock = false
        } else {
          // Start of fenced code block — flush buffered normal lines first.
          let normalText = normalLines.joined(separator: "\n")
          if !normalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append(.normalText(normalText))
          }
          normalLines = []
          inCodeBlock = true
        }
      } else if inCodeBlock {
        codeLines.append(line)
      } else {
        normalLines.append(line)
      }
    }

    // Flush remaining lines (handles unclosed code blocks during streaming).
    if inCodeBlock, !codeLines.isEmpty {
      blocks.append(.codeBlock(codeLines.joined(separator: "\n")))
    } else if !normalLines.isEmpty {
      let t = normalLines.joined(separator: "\n")
      if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        blocks.append(.normalText(t))
      }
    }

    return blocks.isEmpty ? [.normalText(text)] : blocks
  }

  /// Processes a normal-text block line by line, handling headings and table
  /// separator rows, then applying inline formatting to each regular line.
  private static func applyLineMarkdown(
    _ text: String,
    baseAttrs: [NSAttributedString.Key: Any],
    font: UIFont,
    textColor: UIColor
  ) -> NSAttributedString {
    let result = NSMutableAttributedString()
    var addedAny = false

    for line in text.components(separatedBy: "\n") {
      // Skip table separator rows like |---|---|
      if isTableSeparatorLine(line) { continue }

      if addedAny {
        result.append(NSAttributedString(string: "\n", attributes: baseAttrs))
      }

      // Heading lines: # / ## / ###
      if let (level, headingText) = parseHeadingLine(line) {
        result.append(renderHeadingLine(headingText, level: level, baseFont: font, textColor: textColor, baseAttrs: baseAttrs))
        addedAny = true
        continue
      }

      // Regular line with inline formatting (bold, links, code, URLs).
      result.append(applyInlineFormatting(line, baseAttrs: baseAttrs, font: font))
      addedAny = true
    }

    return result
  }

  private static func isTableSeparatorLine(_ line: String) -> Bool {
    let t = line.trimmingCharacters(in: .whitespaces)
    guard t.count > 2, t.hasPrefix("|") else { return false }
    for ch in t { if ch != "|" && ch != "-" && ch != ":" && ch != " " { return false } }
    return true
  }

  private static func parseHeadingLine(_ line: String) -> (Int, String)? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    var level = 0
    var idx = trimmed.startIndex
    while idx < trimmed.endIndex, trimmed[idx] == "#" {
      level += 1
      idx = trimmed.index(after: idx)
    }
    guard level >= 1, level <= 6, idx < trimmed.endIndex, trimmed[idx] == " " else { return nil }
    let content = String(trimmed[trimmed.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
    return content.isEmpty ? nil : (level, content)
  }

  private static func renderHeadingLine(
    _ text: String,
    level: Int,
    baseFont: UIFont,
    textColor: UIColor,
    baseAttrs: [NSAttributedString.Key: Any]
  ) -> NSAttributedString {
    let scale: CGFloat = level == 1 ? 1.22 : level == 2 ? 1.10 : 1.0
    let headingFont: UIFont = {
      if let d = baseFont.fontDescriptor.withSymbolicTraits(.traitBold) {
        return UIFont(descriptor: d, size: round(baseFont.pointSize * scale))
      }
      return UIFont.boldSystemFont(ofSize: round(baseFont.pointSize * scale))
    }()
    // Build a fresh paragraph style without the tight line-height lock.
    let ps = NSMutableParagraphStyle()
    if let existing = baseAttrs[.paragraphStyle] as? NSParagraphStyle { ps.setParagraphStyle(existing) }
    ps.minimumLineHeight = 0
    ps.maximumLineHeight = 0
    var attrs = baseAttrs
    attrs[.font] = headingFont
    attrs[.foregroundColor] = textColor
    attrs[.paragraphStyle] = ps
    attrs.removeValue(forKey: .baselineOffset)
    return NSAttributedString(string: text, attributes: attrs)
  }

  private static func renderCodeBlock(_ code: String, baseFont: UIFont, textColor: UIColor) -> NSAttributedString {
    let monoFont = UIFont.monospacedSystemFont(ofSize: max(11.0, baseFont.pointSize - 2.0), weight: .regular)
    return NSAttributedString(string: code, attributes: [
      .font: monoFont,
      .foregroundColor: textColor.withAlphaComponent(0.85),
    ])
  }

  private static func applyInlineFormatting(
    _ text: String,
    baseAttrs: [NSAttributedString.Key: Any],
    font: UIFont
  ) -> NSAttributedString {
    let mutable = NSMutableAttributedString(string: text, attributes: baseAttrs)

    // 1) Markdown links [label](url) — replace first to preserve offsets.
    let linkMatches = chatNativeAgentMarkdownLinkRegex.matches(
      in: mutable.string,
      range: NSRange(mutable.string.startIndex..., in: mutable.string)
    )
    for match in linkMatches.reversed() {
      guard
        let labelRange = Range(match.range(at: 1), in: mutable.string),
        let urlRange = Range(match.range(at: 2), in: mutable.string)
      else { continue }
      let label = String(mutable.string[labelRange])
      let urlString = String(mutable.string[urlRange])
      mutable.replaceCharacters(in: match.range, with: NSAttributedString(string: label, attributes: baseAttrs))
      let replacedRange = NSRange(location: match.range.location, length: (label as NSString).length)
      if let url = URL(string: urlString) {
        mutable.addAttribute(.link, value: url, range: replacedRange)
        mutable.addAttribute(.foregroundColor, value: UIColor.systemBlue, range: replacedRange)
        mutable.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: replacedRange)
      }
    }

    // 2) Bold **text**
    let boldMatches = chatNativeAgentBoldRegex.matches(
      in: mutable.string,
      range: NSRange(mutable.string.startIndex..., in: mutable.string)
    )
    for match in boldMatches.reversed() {
      guard let range = Range(match.range(at: 1), in: mutable.string) else { continue }
      let boldText = String(mutable.string[range])
      var boldAttrs = baseAttrs
      if let d = font.fontDescriptor.withSymbolicTraits(.traitBold) {
        boldAttrs[.font] = UIFont(descriptor: d, size: font.pointSize)
      } else {
        boldAttrs[.font] = UIFont.boldSystemFont(ofSize: font.pointSize)
      }
      mutable.replaceCharacters(in: match.range, with: NSAttributedString(string: boldText, attributes: boldAttrs))
    }

    // 3) Inline code `code`
    let codeMatches = chatNativeAgentInlineCodeRegex.matches(
      in: mutable.string,
      range: NSRange(mutable.string.startIndex..., in: mutable.string)
    )
    for match in codeMatches.reversed() {
      guard let range = Range(match.range(at: 1), in: mutable.string) else { continue }
      let codeText = String(mutable.string[range])
      var codeAttrs = baseAttrs
      codeAttrs[.font] = UIFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
      mutable.replaceCharacters(in: match.range, with: NSAttributedString(string: codeText, attributes: codeAttrs))
    }

    // 4) Auto-detect bare URLs and style them if not already linked.
    if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
      let urlMatches = detector.matches(
        in: mutable.string,
        options: [],
        range: NSRange(mutable.string.startIndex..., in: mutable.string)
      )
      for m in urlMatches {
        guard let url = m.url else { continue }
        var hasLink = false
        mutable.enumerateAttribute(.link, in: m.range, options: []) { value, _, stop in
          if value != nil { hasLink = true; stop.pointee = true }
        }
        if !hasLink {
          mutable.addAttribute(.link, value: url, range: m.range)
          mutable.addAttribute(.foregroundColor, value: UIColor.systemBlue, range: m.range)
          mutable.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: m.range)
        }
      }
    }

    return mutable
  }

  static func measuredHeight(
    for attributedText: NSAttributedString,
    width: CGFloat
  ) -> CGFloat {
    measuredSize(for: attributedText, width: width).height
  }

  static func measuredWidth(
    for attributedText: NSAttributedString,
    height: CGFloat
  ) -> CGFloat {
    guard height > 1.0, attributedText.length > 0 else { return 0.0 }
    let measured = attributedText.boundingRect(
      with: CGSize(width: .greatestFiniteMagnitude, height: height),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      context: nil
    )
    return ceil(measured.width)
  }

  static func measuredSize(
    for attributedText: NSAttributedString,
    width: CGFloat
  ) -> CGSize {
    guard width > 1.0, attributedText.length > 0 else { return .zero }
    let measured = attributedText.boundingRect(
      with: CGSize(width: width, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      context: nil
    )
    return CGSize(width: ceil(measured.width), height: ceil(measured.height))
  }
}

final class ChatNativeStreamingTextLabel: UITextView, UITextViewDelegate {
  private static let revealInterval: CFTimeInterval = 0.01
  private static let tokenRegex = try! NSRegularExpression(pattern: "\\S+|\\s+")

  private var fullAttributedValue: NSAttributedString?
  private var rawTextValue: String?
  private var tokenRanges: [NSRange] = []
  private var revealedTokenCount = 0
  private var displayLink: CADisplayLink?
  private var nextRevealTime: CFTimeInterval = 0
  weak var linkDelegate: ChatNativeStreamingTextLabelDelegate?
  private static let uuidRegex = try! NSRegularExpression(pattern: "[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}")

  // Compatibility properties for callers using UILabel API
  var numberOfLines: Int {
    get { textContainer.maximumNumberOfLines }
    set { textContainer.maximumNumberOfLines = newValue }
  }

  required init?(coder: NSCoder) {
    return nil
  }

  convenience init() {
    self.init(frame: .zero, textContainer: nil)
  }

  override init(frame: CGRect, textContainer: NSTextContainer?) {
    super.init(frame: frame, textContainer: textContainer)
    isEditable = false
    isScrollEnabled = false
    isSelectable = false
    self.textContainerInset = .zero
    self.textContainer.lineFragmentPadding = 0
    backgroundColor = .clear
    isUserInteractionEnabled = true
    linkTextAttributes = [
      .foregroundColor: UIColor.systemBlue,
      .underlineStyle: NSUnderlineStyle.single.rawValue,
    ]
    delegate = self
  }

  deinit {
    stopStreamingAnimation()
  }

  func applyStreamingText(_ attributedText: NSAttributedString, rawText: String, isStreaming: Bool) {
    let previousRawText = rawTextValue ?? ""
    let shouldContinueExistingAnimation =
      isStreaming
      && !previousRawText.isEmpty
      && rawText.hasPrefix(previousRawText)

    fullAttributedValue = attributedText
    rawTextValue = rawText
    tokenRanges = Self.tokenize(attributedText.string)

    if !shouldContinueExistingAnimation {
      revealedTokenCount = isStreaming ? 0 : tokenRanges.count
      nextRevealTime = 0
    }

    revealedTokenCount = min(revealedTokenCount, tokenRanges.count)
    applyVisibleTokenState()

    if isStreaming {
      isSelectable = false
      startStreamingAnimation()
    } else {
      isSelectable = true
      stopStreamingAnimation()
    }
  }

  func resetStreamingState() {
    stopStreamingAnimation()
    fullAttributedValue = nil
    rawTextValue = nil
    tokenRanges = []
    revealedTokenCount = 0
    attributedText = nil
    isSelectable = false
  }

  private func startStreamingAnimation() {
    guard !tokenRanges.isEmpty else { return }
    guard revealedTokenCount < tokenRanges.count else {
      stopStreamingAnimation()
      return
    }
    guard displayLink == nil else { return }
    let link = CADisplayLink(target: self, selector: #selector(handleDisplayLink))
    link.add(to: .main, forMode: .common)
    displayLink = link
  }

  private func stopStreamingAnimation() {
    displayLink?.invalidate()
    displayLink = nil
    nextRevealTime = 0
  }

  @objc private func handleDisplayLink() {
    guard !tokenRanges.isEmpty else {
      stopStreamingAnimation()
      return
    }

    let now = CACurrentMediaTime()
    if nextRevealTime <= 0 {
      nextRevealTime = now
    }

    var didReveal = false
    while revealedTokenCount < tokenRanges.count, now >= nextRevealTime {
      revealedTokenCount += 1
      nextRevealTime += Self.revealInterval
      didReveal = true
    }

    if didReveal {
      applyVisibleTokenState()
    }

    if revealedTokenCount >= tokenRanges.count {
      stopStreamingAnimation()
      isSelectable = true
    }
  }

  private func applyVisibleTokenState() {
    guard let fullAttributedValue else {
      attributedText = nil
      return
    }

    guard revealedTokenCount < tokenRanges.count else {
      attributedText = fullAttributedValue
      return
    }

    let mutable = NSMutableAttributedString(attributedString: fullAttributedValue)
    for index in revealedTokenCount..<tokenRanges.count {
      let range = tokenRanges[index]
      guard range.location != NSNotFound, range.length > 0, range.location < mutable.length else {
        continue
      }

      var appliedForeground = false
      mutable.enumerateAttribute(.foregroundColor, in: range, options: []) { value, subrange, _ in
        let baseColor = (value as? UIColor) ?? self.textColor ?? .white
        mutable.addAttribute(
          .foregroundColor,
          value: baseColor.withAlphaComponent(0.0),
          range: subrange
        )
        appliedForeground = true
      }

      if !appliedForeground {
        let fallbackColor = (textColor ?? .white).withAlphaComponent(0.0)
        mutable.addAttribute(.foregroundColor, value: fallbackColor, range: range)
      }
    }
    attributedText = mutable
  }

  private static func tokenize(_ string: String) -> [NSRange] {
    guard !string.isEmpty else { return [] }
    let nsString = string as NSString
    let fullRange = NSRange(location: 0, length: nsString.length)
    let matches = tokenRegex.matches(in: string, range: fullRange).map(\.range)
    if matches.isEmpty {
      return [fullRange]
    }
    return matches
  }

  // MARK: - UITextViewDelegate

  func textView(
    _ textView: UITextView,
    shouldInteractWith url: URL,
    in characterRange: NSRange,
    interaction: UITextItemInteraction
  ) -> Bool {
    linkDelegate?.streamingTextLabel(self, didTap: url)
    handleTappedURL(url)
    return false
  }

  private func handleTappedURL(_ url: URL) {
    // If link looks like an internal Vibe chat URL, post a notification to let
    // the app route to the chat; otherwise present an in-app browser modal.
    if let chatId = extractChatId(from: url) {
      NotificationCenter.default.post(
        name: Notification.Name("ChatNative.OpenChat"),
        object: nil,
        userInfo: ["chatId": chatId, "url": url.absoluteString]
      )
      return
    }

    DispatchQueue.main.async {
      InAppBrowserViewController.present(url: url)
    }
  }

  private func extractChatId(from url: URL) -> String? {
    // Heuristic: host contains vibe / vibegram and a UUID appears in the path or query
    let host = url.host?.lowercased() ?? ""
    if host.contains("vibe") || host.contains("vibegram") || url.scheme == "vibe" {
      let path = url.path
      let ns = path as NSString
      let range = NSRange(location: 0, length: ns.length)
      if let m = Self.uuidRegex.firstMatch(in: path, range: range) {
        return (ns.substring(with: m.range) as String)
      }
      if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false), let items = comps.queryItems {
        for item in items {
          if (item.name.lowercased().contains("chat") || item.name.lowercased().contains("id")), let v = item.value, !v.isEmpty {
            return v
          }
        }
      }
    }
    return nil
  }
}
