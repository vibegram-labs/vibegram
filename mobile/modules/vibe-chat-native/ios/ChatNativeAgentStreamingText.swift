import UIKit

private let chatNativeAgentBoldRegex = try! NSRegularExpression(pattern: "\\*\\*(.+?)\\*\\*")

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
    let matches = chatNativeAgentBoldRegex.matches(
      in: text,
      range: NSRange(text.startIndex..., in: text)
    )
    for match in matches.reversed() {
      guard let range = Range(match.range(at: 1), in: text) else { continue }
      let boldText = String(text[range])
      var boldAttrs = attrs
      if let descriptor = font.fontDescriptor.withSymbolicTraits(.traitBold) {
        boldAttrs[.font] = UIFont(descriptor: descriptor, size: font.pointSize)
      } else {
        boldAttrs[.font] = UIFont.boldSystemFont(ofSize: font.pointSize)
      }
      let replacement = NSAttributedString(string: boldText, attributes: boldAttrs)
      mutable.replaceCharacters(in: match.range, with: replacement)
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

  required init?(coder: NSCoder) {
    return nil
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
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
}
