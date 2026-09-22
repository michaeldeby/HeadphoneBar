import Foundation
import HeadphoneProtocol

enum RemoteAction: String, Codable {
    case ancOn = "anc-on", ancOff = "anc-off", transparency
    case bluetooth = "output-bluetooth", btd = "output-btd700"

    func noiseSetting(kind: HeadphoneKind, controls: Controls) throws -> (mode: Int, level: Double?) {
        guard controls.mode != nil else { throw ControlError.message("This headphone cannot confirm its noise-control setting.") }
        let mode: Int
        var level: Double?
        switch kind {
        case .momentum4:
            switch self {
            case .ancOn: mode = 2; level = 0
            case .ancOff: mode = 0
            case .transparency: mode = 2; level = 100
            default: throw ControlError.message("Not a noise-control command.")
            }
        case .sony:
            switch self {
            case .ancOn: mode = 1
            case .ancOff: mode = 0
            case .transparency: mode = 2
            default: throw ControlError.message("Not a noise-control command.")
            }
        case .bose:
            let name: String
            switch self {
            case .ancOn: name = "quiet"
            case .transparency: name = "aware"
            case .ancOff: name = "off"
            default: throw ControlError.message("Not a noise-control command.")
            }
            let matches = controls.modes.filter { $0.name.lowercased() == name }
            guard matches.count == 1 else { throw ControlError.message("This headphone does not expose an unambiguous \(name) mode.") }
            mode = matches[0].id
        default: throw ControlError.message("Noise control is not supported for this headphone.")
        }
        guard controls.modes.contains(where: { $0.id == mode }),
              level.map({ controls.level != nil && controls.levelRange.contains($0) }) ?? true else {
            throw ControlError.message("The requested setting is not supported by this headphone.")
        }
        return (mode, level)
    }
}

// Requests must exist locally; a web page opening a URL cannot issue a command.
@MainActor final class RemoteCommandInbox {
    struct Request: Codable { let action: RemoteAction; let createdAt: Double }
    struct Response: Codable { let success: Bool; let message: String }
    private let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/HeadphoneBar/Raycast", isDirectory: true)
    private var running = false

    func receive(id: String, model: AppModel) {
        guard let uuid = UUID(uuidString: id) else { return }
        let name = uuid.uuidString.lowercased()
        let requestURL = directory.appendingPathComponent(name + ".request.json")
        let responseURL = directory.appendingPathComponent(name + ".response.json")
        guard let data = try? Data(contentsOf: requestURL), data.count < 1024 else { return }
        // Consume before awaiting: a duplicate URL must never replay a write.
        guard (try? FileManager.default.removeItem(at: requestURL)) != nil else { return }
        func reply(_ success: Bool, _ message: String) {
            guard let data = try? JSONEncoder().encode(Response(success: success, message: message)) else { return }
            try? data.write(to: responseURL, options: .atomic)
        }
        guard let request = try? JSONDecoder().decode(Request.self, from: data),
              (0...15).contains(Date().timeIntervalSince1970 - request.createdAt) else {
            reply(false, "The command expired or is invalid. Try again."); return
        }
        guard !running else { reply(false, "Another headphone command is running. Try again when it finishes."); return }
        running = true
        Task {
            defer { running = false }
            do { reply(true, try await model.executeRemote(request.action)) }
            catch { reply(false, error.localizedDescription) }
        }
    }
}
