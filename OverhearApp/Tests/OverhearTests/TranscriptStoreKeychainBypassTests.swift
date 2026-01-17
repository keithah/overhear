@testable import Overhear
import XCTest

final class TranscriptStoreKeychainBypassTests: XCTestCase {

    func testBypassRequiresFlagAndTrustedContext() {
        XCTAssertFalse(TranscriptStore.isKeychainBypassEnabled(environment: [:]))
        XCTAssertFalse(
            TranscriptStore.isKeychainBypassEnabled(
                environment: ["OVERHEAR_INSECURE_NO_KEYCHAIN": "1"]
            ),
            "Bypass flag alone should not enable bypass outside CI/tests"
        )
        XCTAssertFalse(
            TranscriptStore.isKeychainBypassEnabled(
                environment: [
                    "CI": "true",
                    "GITHUB_ACTIONS": "true",
                    "GITHUB_RUNNER_NAME": "runner"
                ]
            ),
            "CI alone should not bypass without explicit opt-in"
        )

        XCTAssertTrue(
            TranscriptStore.isKeychainBypassEnabled(
                environment: [
                    "OVERHEAR_INSECURE_NO_KEYCHAIN": "true",
                    "CI": "true",
                    "GITHUB_ACTIONS": "true",
                    "GITHUB_RUNNER_NAME": "runner"
                ]
            )
        )

        XCTAssertTrue(
            TranscriptStore.isKeychainBypassEnabled(
                environment: [
                    "OVERHEAR_INSECURE_NO_KEYCHAIN": "1",
                    "XCTestConfigurationFilePath": "/tmp/config"
                ]
            )
        )
    }

    func testBypassReasonPrefersTestThenCIThenExplicitFlag() {
        let testEnv = [
            "OVERHEAR_INSECURE_NO_KEYCHAIN": "true",
            "XCTestConfigurationFilePath": "/tmp/config"
        ]
        XCTAssertEqual(
            TranscriptStore.keychainBypassReason(environment: testEnv),
            "XCTestConfigurationFilePath"
        )

        let ciEnv = [
            "OVERHEAR_INSECURE_NO_KEYCHAIN": "1",
            "CI": "true",
            "GITHUB_ACTIONS": "true",
            "GITHUB_RUNNER_NAME": "runner"
        ]
        XCTAssertEqual(
            TranscriptStore.keychainBypassReason(environment: ciEnv),
            "CI/GitHubActions"
        )

        let flagOnlyEnv = ["OVERHEAR_INSECURE_NO_KEYCHAIN": "true"]
        XCTAssertNil(
            TranscriptStore.keychainBypassReason(environment: flagOnlyEnv),
            "Without a trusted context, bypass should not be enabled"
        )

        // When both CI and test markers are present, test context should win.
        let bothEnv = [
            "OVERHEAR_INSECURE_NO_KEYCHAIN": "true",
            "XCTestConfigurationFilePath": "/tmp/config",
            "CI": "true",
            "GITHUB_ACTIONS": "true",
            "GITHUB_RUNNER_NAME": "runner"
        ]
        XCTAssertEqual(
            TranscriptStore.keychainBypassReason(environment: bothEnv),
            "XCTestConfigurationFilePath"
        )
    }
}
