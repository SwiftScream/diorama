import AppKit
import Darwin
import Diorama
import DioramaLocation
import Foundation
import LocationExampleSupport

@main
struct DioramaLocationRecording {
    @MainActor
    static func main() {
        do {
            try LocationApplicationBundle.launchIfNeeded()
        } catch {
            fail(error)
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        Task { @MainActor in
            application.activate(ignoringOtherApps: true)
            do {
                try await record()
                exit(EXIT_SUCCESS)
            } catch {
                fail(error)
            }
        }
        application.run()
    }

    private static func fail(_ error: Error) -> Never {
        let message = "Location recording failed: \(error)\n"
        FileHandle.standardError.write(Data(message.utf8))
        exit(EXIT_FAILURE)
    }

    @MainActor
    private static func record() async throws {
        let path = CommandLine.arguments.dropFirst().first ?? "location.json"
        let file = URL(fileURLWithPath: path).absoluteURL
        let location = try DioramaLocationSystem.instance(named: "gps")
        print("Recording to \(file.path). Return to this terminal and press Return to finish.")
        let result = try await Diorama(file: file, scenarioID: "location-recording", mode: .record, systems: location)
            .execute { _, manager in
                let delegate = LocationPrinter(manager: manager)
                delegate.start()
                await Task.detached { _ = readLine() }.value
                delegate.stop()
            }
        guard case .published = result.publication else {
            print(result.report.rendered())
            throw RecordingError.publicationFailed
        }
        print("Recording written to \(file.path)")
        print(result.report.rendered())
    }
}

private enum RecordingError: Error { case publicationFailed }
