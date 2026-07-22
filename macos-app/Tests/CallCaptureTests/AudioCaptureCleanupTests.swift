import CoreAudio
import Testing
@testable import CallCapture

@Suite("Audio capture cleanup")
struct AudioCaptureCleanupTests {
    @available(macOS 14.2, *)
    @Test("destroy is attempted after a stop error and success permits teardown")
    func destroyAfterStopError() {
        var calls: [String] = []

        let outcome = AudioCaptureManager.performIOProcCleanup(
            stop: {
                calls.append("stop")
                return -101
            },
            destroy: {
                calls.append("destroy")
                return noErr
            }
        )

        #expect(calls == ["stop", "destroy"])
        #expect(outcome.stopStatus == -101)
        #expect(outcome.destroyStatus == noErr)
        #expect(outcome.didDestroy)
    }

    @available(macOS 14.2, *)
    @Test("failed destroy does not permit aggregate or tap teardown")
    func failedDestroyRetainsResources() {
        let outcome = AudioCaptureManager.performIOProcCleanup(
            stop: { noErr },
            destroy: { -202 }
        )

        #expect(outcome.stopStatus == noErr)
        #expect(outcome.destroyStatus == -202)
        #expect(!outcome.didDestroy)
    }
}
