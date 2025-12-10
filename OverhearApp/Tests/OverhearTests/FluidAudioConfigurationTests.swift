import XCTest
@testable import Overhear
#if canImport(FluidAudio)
import FluidAudio

final class FluidAudioConfigurationTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        unsetenv("OVERHEAR_FLUIDAUDIO_ASR_VERSION")
        unsetenv("OVERHEAR_FLUIDAUDIO_ASR_MODELS")
        unsetenv("OVERHEAR_FLUIDAUDIO_DIARIZER_MODELS")
    }

    func testDefaultConfigurationUsesV3() {
        unsetenv("OVERHEAR_FLUIDAUDIO_ASR_VERSION")
        let configuration = FluidAudioConfiguration.fromEnvironment()
        XCTAssertEqual(configuration.asrModelVersion, AsrModelVersion.v3)
    }

    func testVersionEnvironmentOverrides() {
        setenv("OVERHEAR_FLUIDAUDIO_ASR_VERSION", "v2", 1)
        defer { unsetenv("OVERHEAR_FLUIDAUDIO_ASR_VERSION") }
        let configuration = FluidAudioConfiguration.fromEnvironment()
        XCTAssertEqual(configuration.asrModelVersion, AsrModelVersion.v2)
    }

    func testCustomModelDirectories() {
        let asrPath = "/tmp/overhear-fluid-asr"
        let diarizerPath = "/tmp/overhear-fluid-diarizer"
        setenv("OVERHEAR_FLUIDAUDIO_ASR_MODELS", asrPath, 1)
        setenv("OVERHEAR_FLUIDAUDIO_DIARIZER_MODELS", diarizerPath, 1)
        defer {
            unsetenv("OVERHEAR_FLUIDAUDIO_ASR_MODELS")
            unsetenv("OVERHEAR_FLUIDAUDIO_DIARIZER_MODELS")
        }

        let configuration = FluidAudioConfiguration.fromEnvironment()
        XCTAssertEqual(configuration.asrModelsDirectory, URL(fileURLWithPath: asrPath, isDirectory: true))
        XCTAssertEqual(configuration.diarizerModelsDirectory, URL(fileURLWithPath: diarizerPath, isDirectory: true))
    }
}
#else
final class FluidAudioConfigurationTests: XCTestCase {
    func testPlaceholder() throws {
        throw XCTSkip("FluidAudio module is required for these tests")
    }
}
#endif
