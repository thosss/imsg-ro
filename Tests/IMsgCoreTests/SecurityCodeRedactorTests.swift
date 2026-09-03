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
func onlyRedactsClosestOccurrenceNotEveryDigitRun() {
  let text = "Free Msg: Enter code 104414 to activate your Wallet. Contact us at 800-945-3114."
  let result = SecurityCodeRedactor.redact(text)
  #expect(
    result == "Free Msg: Enter code [redacted] to activate your Wallet. Contact us at 800-945-3114."
  )
}
