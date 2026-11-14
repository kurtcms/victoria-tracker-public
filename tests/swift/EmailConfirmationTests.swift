import XCTest

#if canImport(VictoriaTrackerCore)
  @testable import VictoriaTrackerCore
#else
  @testable import VictoriaTracker
#endif

final class EmailConfirmationTests: XCTestCase {
  func testRFC7636ChallengeVector() {
    XCTAssertEqual(
      EmailConfirmation.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
      "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
  }

  func testSecureVerifierShapeAndDistinctness() throws {
    let first = try EmailConfirmation.newVerifier()
    XCTAssertEqual(first.count, 43)
    XCTAssertNotNil(first.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression))
    XCTAssertNotEqual(first, try EmailConfirmation.newVerifier())
  }

  func testSignupUsesExplicitRedirectAndS256WithoutSendingVerifier() throws {
    let c = try XCTUnwrap(URLComponents(string: EmailConfirmation.signupPath))
    XCTAssertEqual(c.path, "/auth/v1/signup")
    XCTAssertEqual(c.queryItems, [URLQueryItem(name: "redirect_to", value: EmailConfirmation.redirect)])
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with:
      EmailConfirmation.signupBody(email: "parent@example.com", password: "test-password", verifier: "private-verifier")) as? [String: String])
    XCTAssertEqual(Set(body.keys), ["email", "password", "code_challenge", "code_challenge_method"])
    XCTAssertEqual(body["code_challenge_method"], "s256")
    XCTAssertEqual(body["code_challenge"], EmailConfirmation.challenge(for: "private-verifier"))
    XCTAssertFalse(body.values.contains("private-verifier"))
  }

  func testOnlyExactCodeCallbackAccepted() throws {
    XCTAssertEqual(try EmailConfirmation.code(from: URL(string: EmailConfirmation.redirect + "?code=example-code")!), "example-code")
    for value in [
      "https://auth/confirm?code=example", "other://auth/confirm?code=example",
      "com.victoriatracker.app://other/confirm?code=example",
      "com.victoriatracker.app://auth/other?code=example",
      "com.victoriatracker.app://parent@auth/confirm?code=example",
      "com.victoriatracker.app://auth:123/confirm?code=example",
      EmailConfirmation.redirect, EmailConfirmation.redirect + "?code=",
      EmailConfirmation.redirect + "?code=one&code=two",
      EmailConfirmation.redirect + "?code=one&access_token=hidden",
      EmailConfirmation.redirect + "#access_token=hidden&refresh_token=hidden",
      EmailConfirmation.redirect + "?code=one#access_token=hidden",
      EmailConfirmation.redirect + "?code=secret%0Atext",
      EmailConfirmation.redirect + "?code=" + String(repeating: "a", count: 1025),
    ] {
      XCTAssertThrowsError(try EmailConfirmation.code(from: URL(string: value)!))
    }
  }

  func testErrorCallbackNeverEchoesParameters() {
    for suffix in ["?error=denied&error_description=private-value", "#error=denied&error_description=private-value"] {
      XCTAssertThrowsError(try EmailConfirmation.code(from: URL(string: EmailConfirmation.redirect + suffix)!)) { error in
        XCTAssertFalse(error.localizedDescription.contains("private-value"))
        XCTAssertFalse(error.localizedDescription.contains(EmailConfirmation.redirect))
      }
    }
  }

  func testPendingSignupRoundTripAndExpiry() throws {
    let now = Date(timeIntervalSince1970: 1800000000)
    let pending = PendingEmailConfirmation(email: "Parent@example.com", verifier: "example-verifier", createdAt: now)
    let restored = try APIJSON.decoder().decode(PendingEmailConfirmation.self, from: APIJSON.encoder().encode(pending))
    XCTAssertEqual(restored, pending)
    XCTAssertTrue(restored.isUsable(for: "parent@example.com", now: now))
    XCTAssertFalse(restored.isUsable(for: "other@example.com", now: now))
    XCTAssertFalse(restored.isUsable(for: pending.email, now: now.addingTimeInterval(86400)))
    XCTAssertFalse(restored.isUsable(for: pending.email, now: now.addingTimeInterval(-1)))
  }
}
