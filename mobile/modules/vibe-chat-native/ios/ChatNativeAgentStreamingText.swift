import UIKit

private let chatNativeAgentBoldRegex = try! NSRegularExpression(pattern: "\\*\\*(.+?)\\*\\*")
private let chatNativeAgentMarkdownLinkRegex = try! NSRegularExpression(pattern: "\\[([^\\]]+)\\]\\((https?://[^)]+)\\)")
private let chatNativeAgentInlineCodeRegex = try! NSRegularExpression(pattern: "`([^`]+)`")

protocol ChatNativeStreamingTextLabelDelegate: AnyObject {
  func streamingTextLabel(_ label: ChatNativeStreamingTextLabel, didTap url: URL)
}

/// Block type emitted by ChatNativeAgentTextRenderer.parseBlocks.
enum AgentParsedBlock: Equatable {
  case text(String)
  case code(String, String?) // code + optional language
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

    return applyLineMarkdown(text, baseAttrs: baseAttrs, font: font, textColor: textColor)
  }

  // MARK: - Block parsing

  /// Split raw markdown into alternating text and fenced-code blocks.
  static func parseBlocks(_ text: String) -> [AgentParsedBlock] {
    var blocks: [AgentParsedBlock] = []
    var normalLines: [String] = []
    var codeLines: [String] = []
    var inCodeBlock = false
    var currentLang: String? = nil
    for line in text.components(separatedBy: "\n") {
      if line.hasPrefix("```") {
        let fenceInfo = String(line.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        if inCodeBlock {
          let code = codeLines.joined(separator: "\n")
          if !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append(.code(code, currentLang))
          }
          codeLines = []
          currentLang = nil
          inCodeBlock = false
        } else {
          let normal = normalLines.joined(separator: "\n")
          if !normal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append(.text(normal))
          }
          normalLines = []
          inCodeBlock = true
          currentLang = fenceInfo.isEmpty ? nil : fenceInfo
        }
      } else if inCodeBlock {
        codeLines.append(line)
      } else {
        normalLines.append(line)
      }
    }
    if inCodeBlock, !codeLines.isEmpty {
      blocks.append(.code(codeLines.joined(separator: "\n"), currentLang))
    } else if !normalLines.isEmpty {
      let t = normalLines.joined(separator: "\n")
      if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { blocks.append(.text(t)) }
    }
    return blocks.isEmpty ? [.text(text)] : blocks
  }

  // MARK: - Line-level markdown

  // MARK: - Line-level helpers

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

    // 4) Auto-detect bare URLs — show clean hostname+path instead of raw URL.
    if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
      let urlMatches = detector.matches(
        in: mutable.string,
        options: [],
        range: NSRange(mutable.string.startIndex..., in: mutable.string)
      ).reversed()
      for m in urlMatches {
        guard let url = m.url else { continue }
        var hasLink = false
        mutable.enumerateAttribute(.link, in: m.range, options: []) { value, _, stop in
          if value != nil { hasLink = true; stop.pointee = true }
        }
        if !hasLink {
          let display = cleanURLDisplay(url)
          var linkAttrs = baseAttrs
          linkAttrs[.link] = url
          linkAttrs[.foregroundColor] = UIColor.systemBlue
          linkAttrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
          mutable.replaceCharacters(
            in: m.range,
            with: NSAttributedString(string: display, attributes: linkAttrs)
          )
        }
      }
    }

    return mutable
  }

  private static func cleanURLDisplay(_ url: URL) -> String {
    guard let host = url.host else { return url.absoluteString }
    let h = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    let path = url.path
    guard !path.isEmpty, path != "/" else { return h }
    let p = path.count > 28 ? String(path.prefix(28)) + "\u{2026}" : path
    return h + p
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

// MARK: - AgentCodeBlockView

final class AgentCodeBlockView: UIView {
  private let cardView = UIView()
  private let topBarView = UIView()
  private let langLabel = UILabel()
  private let codeLabel = UILabel()
  private let copyButton = UIButton(type: .system)
  private let expandButton = UIButton(type: .system)
  private let copiedLabel = UILabel()
  private var codeContent = ""
  private var codeLang: String?
  private var codeFont = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
  private var baseTextColor = UIColor.white
  private var isExpanded = false
  private var maxCollapsedLines = 12
  private var totalLineCount = 0
  private var copyFeedbackWork: DispatchWorkItem?
  private var currentAvailableWidth: CGFloat = 0

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false

    cardView.layer.cornerRadius = 10.0
    cardView.layer.cornerCurve = .continuous
    cardView.clipsToBounds = true
    addSubview(cardView)

    topBarView.backgroundColor = UIColor(white: 0.5, alpha: 0.06)
    cardView.addSubview(topBarView)

    langLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .medium)
    langLabel.textColor = UIColor(white: 0.65, alpha: 0.9)
    topBarView.addSubview(langLabel)

    codeLabel.numberOfLines = 0
    codeLabel.backgroundColor = .clear
    cardView.addSubview(codeLabel)

    let cfg = UIImage.SymbolConfiguration(pointSize: 12.0, weight: .medium)
    copyButton.setImage(UIImage(systemName: "doc.on.doc", withConfiguration: cfg), for: .normal)
    copyButton.tintColor = UIColor(white: 0.65, alpha: 0.9)
    copyButton.addTarget(self, action: #selector(handleCopy), for: .touchUpInside)
    topBarView.addSubview(copyButton)

    expandButton.setImage(UIImage(systemName: "arrow.up.left.and.arrow.down.right", withConfiguration: cfg), for: .normal)
    expandButton.tintColor = UIColor(white: 0.65, alpha: 0.9)
    expandButton.addTarget(self, action: #selector(handleExpand), for: .touchUpInside)
    topBarView.addSubview(expandButton)

    copiedLabel.text = "Copied!"
    copiedLabel.font = .systemFont(ofSize: 11.0, weight: .medium)
    copiedLabel.textColor = UIColor.systemGreen
    copiedLabel.alpha = 0
    topBarView.addSubview(copiedLabel)
  }

  required init?(coder: NSCoder) { return nil }

  @discardableResult
  func configure(code: String, language: String? = nil, textColor: UIColor, baseFont: UIFont, availableWidth: CGFloat) -> CGFloat {
    codeContent = code
    codeLang = language
    baseTextColor = textColor
    currentAvailableWidth = availableWidth
    codeFont = UIFont.monospacedSystemFont(ofSize: max(12.5, baseFont.pointSize - 2.5), weight: .regular)

    let outerH: CGFloat = 0.0
    let hPad: CGFloat = 12.0
    let vPad: CGFloat = 10.0
    let barH: CGFloat = 32.0
    let btnW: CGFloat = 30.0
    let cardWidth = max(1.0, availableWidth - outerH * 2)
    let labelWidth = max(1.0, cardWidth - hPad * 2)

    // Language label
    langLabel.text = language?.lowercased()
    langLabel.isHidden = language == nil

    // Count total lines
    totalLineCount = code.components(separatedBy: "\n").count

    // Determine display text (collapsed vs expanded)
    let displayCode: String
    let needsCollapse = !isExpanded && totalLineCount > maxCollapsedLines
    if needsCollapse {
      displayCode = code.components(separatedBy: "\n").prefix(maxCollapsedLines).joined(separator: "\n")
    } else {
      displayCode = code
    }

    // Plain monospace by default; colorized when expanded
    let attributed: NSAttributedString
    if isExpanded {
      attributed = highlightedCode(displayCode, font: codeFont, baseColor: textColor)
    } else {
      attributed = NSAttributedString(string: displayCode, attributes: [
        .font: codeFont,
        .foregroundColor: textColor.withAlphaComponent(0.88)
      ])
    }
    codeLabel.attributedText = attributed

    let textHeight = ceil(attributed.boundingRect(
      with: CGSize(width: labelWidth, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil
    ).height)
    let bodyH = max(ceil(codeFont.lineHeight), textHeight)
    let cardH = barH + vPad + bodyH + vPad

    cardView.backgroundColor = UIColor(white: 0.5, alpha: 0.09)
    cardView.layer.borderWidth = 0.5
    cardView.layer.borderColor = UIColor(white: 0.5, alpha: 0.18).cgColor
    cardView.frame = CGRect(x: outerH, y: 0, width: cardWidth, height: cardH)
    topBarView.frame = CGRect(x: 0, y: 0, width: cardWidth, height: barH)

    // Top bar layout: [langLabel ...  copyBtn  expandBtn]
    langLabel.sizeToFit()
    langLabel.frame = CGRect(x: hPad, y: (barH - langLabel.frame.height) * 0.5,
                             width: langLabel.frame.width, height: langLabel.frame.height)

    expandButton.frame = CGRect(x: cardWidth - btnW - 4.0, y: (barH - btnW) * 0.5, width: btnW, height: btnW)
    copyButton.frame = CGRect(x: expandButton.frame.minX - btnW, y: (barH - btnW) * 0.5, width: btnW, height: btnW)

    copiedLabel.sizeToFit()
    copiedLabel.frame.origin = CGPoint(
      x: copyButton.frame.minX - copiedLabel.frame.width - 6.0,
      y: (barH - copiedLabel.frame.height) * 0.5
    )

    // Update expand icon
    let expandCfg = UIImage.SymbolConfiguration(pointSize: 12.0, weight: .medium)
    let expandIcon = isExpanded
      ? "arrow.down.right.and.arrow.up.left"
      : "arrow.up.left.and.arrow.down.right"
    expandButton.setImage(UIImage(systemName: expandIcon, withConfiguration: expandCfg), for: .normal)
    expandButton.isHidden = totalLineCount <= maxCollapsedLines

    codeLabel.frame = CGRect(x: hPad, y: barH + vPad, width: labelWidth, height: bodyH)
    return outerH + cardH + 8.0
  }

  // MARK: - Syntax highlighting (only used in expanded mode)

  private func highlightedCode(_ code: String, font: UIFont, baseColor: UIColor) -> NSAttributedString {
    let mutable = NSMutableAttributedString(string: code, attributes: [
      .font: font,
      .foregroundColor: baseColor.withAlphaComponent(0.88)
    ])
    let fullRange = NSRange(location: 0, length: (code as NSString).length)

    // Keywords
    let kw = "func|let|var|if|else|for|while|return|class|struct|enum|import|extension|guard|in|where|as|try|catch|throw|switch|case|default|public|private|protocol|static|const|function|new|this|super|await|async|yield|package|interface|implements|override|final|val|def|namespace|using|fn|mut|use|mod|pub|impl|type|trait|match|loop|break|continue|self|Self|nil|null|true|false|None|Some"
    if let re = try? NSRegularExpression(pattern: "\\b(\(kw))\\b") {
      for m in re.matches(in: code, range: fullRange) {
        mutable.addAttribute(.foregroundColor, value: UIColor.systemPink, range: m.range)
      }
    }

    // Types / Macros (capitalized words, or word!)
    if let re = try? NSRegularExpression(pattern: "\\b[A-Z][a-zA-Z0-9_]*\\b|\\b[a-z_]+!") {
      for m in re.matches(in: code, range: fullRange) {
        mutable.addAttribute(.foregroundColor, value: UIColor(red: 0.4, green: 0.75, blue: 1.0, alpha: 1.0), range: m.range)
      }
    }

    // Numbers
    if let re = try? NSRegularExpression(pattern: "\\b\\d+(?:\\.\\d+)?\\b") {
      for m in re.matches(in: code, range: fullRange) {
        mutable.addAttribute(.foregroundColor, value: UIColor.systemOrange, range: m.range)
      }
    }

    // Strings
    if let re = try? NSRegularExpression(pattern: "\"(?:\\\\.|[^\"\\\\])*\"|'(?:\\\\.|[^'\\\\])*'") {
      for m in re.matches(in: code, range: fullRange) {
        mutable.addAttribute(.foregroundColor, value: UIColor.systemGreen, range: m.range)
      }
    }

    // Comments (must be last to override)
    if let re = try? NSRegularExpression(pattern: "//.*|#.*|/\\*[\\s\\S]*?\\*/", options: [.dotMatchesLineSeparators, .anchorsMatchLines]) {
      for m in re.matches(in: code, range: fullRange) {
        mutable.addAttribute(.foregroundColor, value: UIColor(white: 0.55, alpha: 1.0), range: m.range)
      }
    }

    return mutable
  }

  @objc private func handleExpand() {
    isExpanded.toggle()
    _ = configure(code: codeContent, language: codeLang, textColor: baseTextColor, baseFont: codeFont, availableWidth: currentAvailableWidth)

    // Trigger parent re-layout
    if let sv = superview {
      sv.setNeedsLayout()
      sv.layoutIfNeeded()
    }
    // Post notification so the table/collection can invalidate its layout
    NotificationCenter.default.post(name: Notification.Name("AgentCodeBlockExpanded"), object: nil)
  }

  @objc private func handleCopy() {
    UIPasteboard.general.string = codeContent
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    copyFeedbackWork?.cancel()
    copiedLabel.alpha = 0
    copyButton.alpha = 0
    UIView.animate(withDuration: 0.15) { self.copiedLabel.alpha = 1.0 }
    let work = DispatchWorkItem { [weak self] in
      UIView.animate(withDuration: 0.25) {
        self?.copiedLabel.alpha = 0
        self?.copyButton.alpha = 1.0
      }
    }
    copyFeedbackWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
  }
}

// MARK: - ChatNativeStreamingTextLabel

final class ChatNativeStreamingTextLabel: UITextView {
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
    let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
    tap.cancelsTouchesInView = false
    addGestureRecognizer(tap)
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
      startStreamingAnimation()
    } else {
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

  // MARK: - Link tap (layout manager hit-test — no cursor, isSelectable stays false)

  @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
    guard let attributed = attributedText, attributed.length > 0 else { return }
    let point = gesture.location(in: self)
    let adjusted = CGPoint(
      x: point.x - textContainerInset.left,
      y: point.y - textContainerInset.top
    )
    let charIdx = layoutManager.characterIndex(
      for: adjusted, in: textContainer,
      fractionOfDistanceBetweenInsertionPoints: nil
    )
    guard charIdx < attributed.length else { return }
    let attrs = attributed.attributes(at: charIdx, effectiveRange: nil)
    if let linkVal = attrs[.link] {
      var url: URL?
      if let u = linkVal as? URL { url = u }
      else if let s = linkVal as? String { url = URL(string: s) }
      if let url {
        linkDelegate?.streamingTextLabel(self, didTap: url)
        handleTappedURL(url)
      }
    }
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
