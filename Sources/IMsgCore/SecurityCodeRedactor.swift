import Foundation

/// Best-effort redaction of texted security/verification codes (2FA, OTP,
/// bank and vendor verification codes) from message text, for callers that
/// don't want a downstream consumer — an AI agent in particular — to see live
/// codes.
///
/// This is a heuristic, not a guarantee. Real-world SMS OTP messages were
/// mined from a live chat.db to derive it: the code can appear either before
/// or after the keyword ("123456 is your code" is at least as common as
/// "code: 123456" — it's the autofill-friendly format several major senders
/// use), and some senders format it with internal dashes ("657-265"). It is
/// deliberately restricted to digits and dashes, so alphanumeric codes (e.g.
/// "7fpa1i") are not redacted — accepted as a known, rare miss.
///
/// **Every** keyword-adjacent token is redacted, not just the nearest one.
/// Redacting a single token was a real leak, found by running this matcher
/// over a live chat.db: it spends its one replacement on whichever token sits
/// closest to a keyword, which is not always the secret. Two shapes from that
/// corpus, both of which left the actual secret in the clear:
///
///     Citi card ending in [redacted]. … enter one-time passcode 082156.
///     San Francisco, CA [redacted] / Smart lock code for front door: 26179
///
/// The card's last four and the ZIP won; the OTP and the door code survived.
/// A message can also simply carry two codes ("Alarm Code for Legacy System:
/// …" then "Alarm Code for Ring: …"), where the second was never considered.
/// Redacting all matches costs some false positives on non-secrets, which is
/// the right trade for a caller that asked for redaction in the first place.
public enum SecurityCodeRedactor {
  public static let placeholder = "[redacted]"

  private static let keyword = "(?:code|pin|otp|passcode|authentication)"
  private static let token = "\\d[\\d\\-]{2,8}\\d"
  private static let windowChars = 60

  /// Longest digit-and-dash run a candidate may sit inside before it is read
  /// as a phone number rather than a code.
  ///
  /// This is what keeps redact-everything from mangling support numbers:
  /// "Didn't request a code? Call 1-800-387-2331" puts a phone number one
  /// keyword away with no digits in between, so it matches, and the token
  /// pattern caps at ten characters — enough to chew "1-800-387" out of the
  /// middle and leave "-2331" behind. Separator-formatted phone numbers run
  /// 12–14 characters, while codes (including dashed ones like "657-265" and
  /// the "G-123456" web-OTP prefix, whose run starts at the dash) stay at or
  /// under ten.
  private static let maximumRunLength = 10

  // The gap between keyword and token deliberately excludes digits. Without
  // that restriction, a real but unmatchable code right next to the keyword
  // (e.g. the alphanumeric "7fpa1i" in "verification code is: 7fpa1i") gets
  // skipped over by the lazy quantifier, which then keeps searching and can
  // latch onto an unrelated digit run later in the message (e.g. a support
  // phone number). Excluding digits from the gap means the match fails
  // outright at that keyword occurrence instead of reaching past it.
  private static let forward = try! NSRegularExpression(
    pattern: "\\b\(keyword)\\b([^\\d]{0,\(windowChars)})\\b(\(token))\\b",
    options: [.caseInsensitive, .dotMatchesLineSeparators]
  )
  private static let backward = try! NSRegularExpression(
    pattern: "\\b(\(token))\\b([^\\d]{0,\(windowChars)})\\b\(keyword)\\b",
    options: [.caseInsensitive, .dotMatchesLineSeparators]
  )
  private static let url = try! NSRegularExpression(
    pattern: "https?://\\S+|www\\.\\S+",
    options: [.caseInsensitive]
  )

  /// Returns `text` with every code-shaped token adjacent to a security-code
  /// keyword replaced by `placeholder`, or `text` unchanged if none matched.
  public static func redact(_ text: String) -> String {
    let ranges = redactionRanges(in: text)
    guard !ranges.isEmpty else { return text }
    let result = NSMutableString(string: text)
    // Right to left, so each replacement leaves the earlier offsets valid.
    for range in ranges.reversed() {
      result.replaceCharacters(in: range, with: placeholder)
    }
    return result as String
  }

  public static func redact(_ text: String?) -> String? {
    guard let text else { return nil }
    return redact(text)
  }

  /// Token ranges to replace, ordered by position and free of overlaps.
  private static func redactionRanges(in text: String) -> [NSRange] {
    let ns = text as NSString
    let full = NSRange(location: 0, length: ns.length)
    guard full.length > 0 else { return [] }
    let urlRanges = url.matches(in: text, options: [], range: full).map { $0.range }

    var found: [NSRange] = []
    for (regex, tokenGroup) in [(forward, 2), (backward, 1)] {
      for match in regex.matches(in: text, options: [], range: full) {
        let tokenRange = match.range(at: tokenGroup)
        guard tokenRange.location != NSNotFound else { continue }
        // A code quoted inside a link is part of the URL, not a separate
        // secret; rewriting it would corrupt the link for no benefit.
        guard !urlRanges.contains(where: { NSIntersectionRange($0, tokenRange).length > 0 })
        else { continue }
        guard runLength(in: ns, containing: tokenRange) <= maximumRunLength else { continue }
        found.append(tokenRange)
      }
    }

    // The two directions can flag the same token ("code 1234 code"), so merge
    // before replacing — overlapping replacements would corrupt the output.
    found.sort { $0.location < $1.location }
    var merged: [NSRange] = []
    for range in found {
      if let last = merged.last, NSMaxRange(last) > range.location {
        merged[merged.count - 1] = NSUnionRange(last, range)
      } else {
        merged.append(range)
      }
    }
    return merged
  }

  /// Length of the maximal digit-and-dash run that `range` sits inside.
  private static func runLength(in ns: NSString, containing range: NSRange) -> Int {
    var start = range.location
    while start > 0, isDigitOrDash(ns.character(at: start - 1)) { start -= 1 }
    var end = NSMaxRange(range)
    while end < ns.length, isDigitOrDash(ns.character(at: end)) { end += 1 }
    return end - start
  }

  private static func isDigitOrDash(_ character: unichar) -> Bool {
    (character >= 0x30 && character <= 0x39) || character == 0x2D
  }
}
