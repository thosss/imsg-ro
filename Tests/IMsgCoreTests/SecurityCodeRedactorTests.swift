import Foundation
import Testing

@testable import IMsgCore

// Fixtures below are real SMS text shapes mined from a live chat.db while
// building this feature (senders redacted where irrelevant; every literal
// code is long expired). They exist to keep the regex honest against
// real-world formatting rather than synthetic examples.

@Test
func redactsCodeThenDigitsForward() {
  let text = "Verification code: 8353"
  #expect(SecurityCodeRedactor.redact(text) == "Verification code: [redacted]")
}

@Test
func redactsDigitsThenCodeBackward() {
  // The more common real-world shape: autofill-friendly senders (Google,
  // PayPal, Coinbase, Schwab, Walgreens, Citi, Ticketmaster, ...) put the
  // code first.
  let text = "873934 is your Ticketmaster code."
  #expect(SecurityCodeRedactor.redact(text) == "[redacted] is your Ticketmaster code.")
}

@Test
func redactsWebOTPStylePrefix() {
  let text = "G-164937 is your Google verification code."
  #expect(SecurityCodeRedactor.redact(text) == "G-[redacted] is your Google verification code.")
}

@Test
func redactsDashedCode() {
  let text = "Your WhatsApp code is 657-265 but you can simply tap on this link to verify."
  #expect(
    SecurityCodeRedactor.redact(text)
      == "Your WhatsApp code is [redacted] but you can simply tap on this link to verify.")
}

@Test
func redactsPasscodeKeyword() {
  let text = "USPS Identity Services: Your one time passcode is 974539."
  #expect(
    SecurityCodeRedactor.redact(text)
      == "USPS Identity Services: Your one time passcode is [redacted]."
  )
}

@Test
func redactsAuthenticationKeyword() {
  let text = "Use 015048 for two-factor authentication on Facebook."
  #expect(
    SecurityCodeRedactor.redact(text) == "Use [redacted] for two-factor authentication on Facebook."
  )
}

@Test
func redactsPinKeyword() {
  let text = "Free Text Msg: enter pin 3590068 to confirm."
  #expect(SecurityCodeRedactor.redact(text) == "Free Text Msg: enter pin [redacted] to confirm.")
}

@Test
func doesNotRedactAlphanumericCodes() {
  // Deliberate, accepted miss: token must be digits-and-dashes only.
  let text =
    "State Farm: Your verification code is: 7fpa1i. If you didn't request this, call 888-559-1922."
  #expect(SecurityCodeRedactor.redact(text) == text)
}

@Test
func doesNotRedactDressCodeIdiom() {
  let text = "Do we have an update on the dress code for tomorrow?"
  #expect(SecurityCodeRedactor.redact(text) == text)
}

@Test
func doesNotRedactCouponCode() {
  // Coupon codes phrased identically to OTP language are an accepted,
  // low-stakes false-positive risk in general, but this one happens to be
  // alphanumeric, so it's excluded by the digit-only token rule too.
  let text = "Get up to 15% off with code GREATMOVE15."
  #expect(SecurityCodeRedactor.redact(text) == text)
}

@Test
func doesNotRedactTokenInsideURL() {
  let text = "714740 is your Google Voice verification code. Don't share it. https://goo.gl/UERgF7"
  let result = SecurityCodeRedactor.redact(text)
  #expect(
    result
      == "[redacted] is your Google Voice verification code. Don't share it. https://goo.gl/UERgF7")
  #expect(result.contains("UERgF7"))
}

@Test
func picksRealCodeOverDecoyPhoneNumberNearRepeatedKeyword() {
  // Real message shape: "code" is repeated, with a support phone number
  // appearing near a later, unrelated mention. The nearest pairing to the
  // FIRST keyword occurrence must win.
  let text =
    "Your E*TRADE verification code is 758227. No one from E*TRADE will contact you for this "
    + "code unless initiated by you. Didn't request a code? Call 1-800-387-2331"
  let result = SecurityCodeRedactor.redact(text)
  #expect(result.contains("[redacted]"))
  #expect(!result.contains("758227"))
  #expect(result.contains("1-800-387-2331"))
}

@Test
func doesNotRedactMessageWithNoCodePresent() {
  let text = "Your Eligibility Code is available now! Present it at the front desk."
  #expect(SecurityCodeRedactor.redact(text) == text)
}

@Test
func doesNotRedactUnrelatedMessage() {
  let text = "Are we still on for dinner tonight?"
  #expect(SecurityCodeRedactor.redact(text) == text)
}

@Test
func doesNotRedactPhoneNumberSeparatedFromKeywordByDigits() {
  // Two guards keep the support number intact now that every match is
  // redacted: digits in the keyword-to-token gap end the match, and the
  // number's 12-character digit-and-dash run is longer than a code's.
  let text = "Free Msg: Enter code 104414 to activate your Wallet. Contact us at 800-945-3114."
  let result = SecurityCodeRedactor.redact(text)
  #expect(
    result == "Free Msg: Enter code [redacted] to activate your Wallet. Contact us at 800-945-3114."
  )
}

// MARK: - Multiple codes in one message
//
// Every case below is a real message shape from a live chat.db. Under the old
// single-replacement rule each one leaked: the first three left the actual
// secret in the clear, because the token nearest a keyword was not the secret.

@Test
func redactsOTPEvenWhenCardDigitsSitNearerTheKeyword() {
  let text =
    "BEWARE DO NOT GIVE THIS CODE TO ANYONE. Citi card ending in 8940. "
    + "For online purchase of (EUR) 0.00 with EUROSTARS GRAND CENTRAL enter one-time passcode 082156."
  let result = SecurityCodeRedactor.redact(text)
  #expect(!result.contains("082156"), "the one-time passcode must not survive")
  #expect(!result.contains("8940"))
}

@Test
func redactsDoorCodeEvenWhenZIPSitsNearerTheKeyword() {
  let text =
    "My address\n4057 19th Street\nSan Francisco, CA 94114\n\nSmart lock code for front door: 26179"
  let result = SecurityCodeRedactor.redact(text)
  #expect(!result.contains("26179"), "the door code must not survive")
  #expect(!result.contains("94114"))
  // The street number is not keyword-adjacent, so it is left alone.
  #expect(result.contains("4057 19th Street"))
}

@Test
func redactsBothCodesWhenAMessageCarriesTwo() {
  let text =
    "Alarm Code for Legacy System (panel on wall): 3333 enter\n"
    + "Alarm Code for Ring (panel is on the stairs): 4444 disarm button"
  let result = SecurityCodeRedactor.redact(text)
  #expect(!result.contains("3333"))
  #expect(!result.contains("4444"), "the second code must not survive")
  #expect(result.components(separatedBy: "[redacted]").count == 3)
}

@Test
func leavesDashedPhoneNumberWholeRatherThanChewingItsMiddle() {
  // The token pattern caps at ten characters, so without the run-length guard
  // "888-725" would be redacted out of the middle, leaving a stray "-7020".
  let text = "Tap the link or call 888-725-7020 & zip code, or reply STOP."
  let result = SecurityCodeRedactor.redact(text)
  #expect(result == text)
}
