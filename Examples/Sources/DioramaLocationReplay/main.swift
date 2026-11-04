import Darwin
import Diorama
import DioramaLocation
import Foundation
import LocationExampleSupport

@main
struct DioramaLocationReplay {
    @MainActor
    static func main() async {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(Data("Usage: DioramaLocationReplay <recording.json>\n".utf8))
            exit(EXIT_FAILURE)
        }
        do {
            let file = URL(fileURLWithPath: CommandLine.arguments[1]).absoluteURL
            let location = try DioramaLocationSystem.instance(named: "gps")
            print("Replaying \(file.path). Press Return to finish.")
            let result = try await Diorama(file: file, scenarioID: "location-replay", mode: .replay, systems: location)
                .execute { _, manager in
                    let delegate = LocationPrinter(manager: manager)
                    delegate.start()
                    await Task.detached { _ = readLine() }.value
                    delegate.stop()
                }
            print("Replay finished for \(file.path)")
            print(result.report.rendered())
        } catch {
            FileHandle.standardError.write(Data("Location replay failed: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
}
