import XCTest
@testable import PokeTokenBar

final class SecurityHardeningTests: XCTestCase {
    func testCloudCodeOverrideRequiresTrustedGoogleHTTPSOrigin() {
        XCTAssertEqual(
            UsageEnvironment.trustedCloudCodeBaseURL("https://cloudcode-pa.googleapis.com"),
            "https://cloudcode-pa.googleapis.com")
        XCTAssertEqual(
            UsageEnvironment.trustedCloudCodeBaseURL("https://daily-cloudcode-pa.googleapis.com/"),
            "https://daily-cloudcode-pa.googleapis.com")

        XCTAssertNil(UsageEnvironment.trustedCloudCodeBaseURL("http://cloudcode-pa.googleapis.com"))
        XCTAssertNil(UsageEnvironment.trustedCloudCodeBaseURL("https://googleapis.com.evil.example"))
        XCTAssertNil(UsageEnvironment.trustedCloudCodeBaseURL("https://evilgoogleapis.com"))
        XCTAssertNil(UsageEnvironment.trustedCloudCodeBaseURL("https://user:pass@cloudcode-pa.googleapis.com"))
        XCTAssertNil(UsageEnvironment.trustedCloudCodeBaseURL("https://cloudcode-pa.googleapis.com:8443"))
    }

    func testApplicationLogRedactsCommonCredentialForms() {
        let input = "Authorization: Bearer abc.def.ghi access_token=secret-value api_key='key-value' sk-example12345678"
        let output = AppLog.redacted(input)

        XCTAssertFalse(output.contains("abc.def.ghi"))
        XCTAssertFalse(output.contains("secret-value"))
        XCTAssertFalse(output.contains("key-value"))
        XCTAssertFalse(output.contains("sk-example12345678"))
        XCTAssertTrue(output.contains("[REDACTED]"))
    }
}
