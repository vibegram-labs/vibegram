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

    var attrs: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: textColor,
      .paragraphStyle: paragraphStyle,
    ]
    if let lineHeight {
      attrs[.baselineOffset] = (lineHeight - font.lineHeight) * 0.25
    }
    let mutable = NSMutableAttributedString(string: text, attributes: attrs)

    // 1) Parse Markdown links [label](https://...) first so indices remain valid.
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
      let replacement = NSAttributedString(string: label, attributes: attrs)
      mutable.replaceCharacters(in: match.range, with: replacement)
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
      var boldAttrs = attrs
      if let descriptor = font.fontDescriptor.withSymbolicTraits(.traitBold) {
        boldAttrs[.font] = UIFont(descriptor: descriptor, size: font.pointSize)
      } else {
        boldAttrs[.font] = UIFont.boldSystemFont(ofSize: font.pointSize)
      }
      let replacement = NSAttributedString(string: boldText, attributes: boldAttrs)
      mutable.replaceCharacters(in: match.range, with: replacement)
    }

    // 3) Inline code `code`
    let codeMatches = chatNativeAgentInlineCodeRegex.matches(
      in: mutable.string,
      range: NSRange(mutable.string.startIndex..., in: mutable.string)
    )
    for match in codeMatches.reversed() {
      guard let range = Range(match.range(at: 1), in: mutable.string) else { continue }
      let codeText = String(mutable.string[range])
      var codeAttrs = attrs
      codeAttrs[.font] = UIFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
      codeAttrs[.backgroundColor] = UIColor(white: 0.95, alpha: 1.0)
      let replacement = NSAttributedString(string: codeText, attributes: codeAttrs)
      mutable.replaceCharacters(in: match.range, with: replacement)
    }

    // 4) Auto-detect bare URLs (e.g. https://...) and style them if not already linked.
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

final class ChatNativeStreamingTextLabel: UILabel {
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

  required init?(coder: NSCoder) {
    return nil
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = true
    let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
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
    super.attributedText = nil
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
      super.attributedText = nil
      return
    }

    guard revealedTokenCount < tokenRanges.count else {
      super.attributedText = fullAttributedValue
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
    super.attributedText = mutable
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

  @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
    guard let attributed = attributedText, attributed.length > 0 else { return }

    // Build layout manager for hit-testing
    let textStorage = NSTextStorage(attributedString: attributed)
    let layoutManager = NSLayoutManager()
    textStorage.addLayoutManager(layoutManager)
    let textContainer = NSTextContainer(size: bounds.size)
    textContainer.lineFragmentPadding = 0
    textContainer.maximumNumberOfLines = numberOfLines
    textContainer.lineBreakMode = lineBreakMode
    layoutManager.addTextContainer(textContainer)

    let location = gesture.location(in: self)
    // Compute y offset for vertical alignment
    let usedRect = layoutManager.usedRect(for: textContainer)
    let yOffset = (bounds.size.height - usedRect.size.height) / 2 - usedRect.origin.y
    let textContainerPoint = CGPoint(x: location.x, y: location.y - yOffset)

    let index = layoutManager.characterIndex(for: textContainerPoint, in: textContainer, fractionOfDistanceBetweenInsertionPoints: nil)
    guard index < textStorage.length else { return }

    var range = NSRange(location: 0, length: 0)
    let attrs = attributed.attributes(at: index, effectiveRange: &range)
    if let linkValue = attrs[.link] {
      var url: URL?
      if let u = linkValue as? URL { url = u }
      else if let s = linkValue as? String { url = URL(string: s) }
      if let url {
        // Delegate first
        linkDelegate?.streamingTextLabel(self, didTap: url)
        // Default handling: open in-app browser or route to internal chat
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
