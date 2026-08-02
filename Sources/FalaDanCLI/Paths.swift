import Foundation

enum PathResolver {
    static func fileURL(for path: String) -> URL {
        URL(fileURLWithPath: expandTilde(path)).standardizedFileURL
    }

    static func expandTilde(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let suffix = path.dropFirst(path == "~" ? 1 : 2)
        return suffix.isEmpty ? home : "\(home)/\(suffix)"
    }
}

enum FalaDanPaths {
    static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    static var fluidAudioModelsRoot: URL {
        applicationSupport
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    static var whisperModels: URL {
        applicationSupport
            .appendingPathComponent("FalaDan", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
    }

    static var whisperModel: URL {
        whisperModels.appendingPathComponent("ggml-large-v3-turbo-q8_0.bin")
    }

    static var whisperVADModel: URL {
        whisperModels.appendingPathComponent("ggml-silero-v6.2.0.bin")
    }

    static var claudeSkills: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
    }

    static var codexSkills: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
    }

    static var coreSkillClaudeInstall: URL {
        claudeSkills.appendingPathComponent(CoreSkill.directoryName, isDirectory: true)
    }

    static var coreSkillCodexInstall: URL {
        codexSkills.appendingPathComponent(CoreSkill.directoryName, isDirectory: true)
    }
}

struct PathsOutput: Encodable {
    let executable: String
    let fluidAudioModels: String
    let parakeet: String
    let parakeetInstalled: Bool
    let falaDanWhisperModels: String
    let whisperModel: String
    let whisperModelInstalled: Bool
    let whisperVADModel: String
    let whisperVADModelInstalled: Bool
    let claudeSkills: String
    let claudeSkill: String
    let codexSkills: String
    let codexSkill: String

    enum CodingKeys: String, CodingKey {
        case executable
        case fluidAudioModels = "fluid_audio_models"
        case parakeet
        case parakeetInstalled = "parakeet_installed"
        case falaDanWhisperModels = "faladan_whisper_models"
        case whisperModel = "whisper_model"
        case whisperModelInstalled = "whisper_model_installed"
        case whisperVADModel = "whisper_vad_model"
        case whisperVADModelInstalled = "whisper_vad_model_installed"
        case claudeSkills = "claude_skills"
        case claudeSkill = "claude_skill"
        case codexSkills = "codex_skills"
        case codexSkill = "codex_skill"
    }
}

enum PathsCommand {
    static func run(arguments: [String]) -> Int32 {
        if arguments.contains("-h") || arguments.contains("--help") {
            printHelp()
            return 0
        }

        let emitJSON = arguments.contains("--json")
        let unknown = arguments.first { $0 != "--json" }
        if let unknown {
            Console.error("Unknown paths option: \(unknown)")
            return 2
        }

        let output = PathsOutput(
            executable: Bundle.main.executableURL?.path ?? "faladancli",
            fluidAudioModels: FalaDanPaths.fluidAudioModelsRoot.path,
            parakeet: ParakeetModel.directory.path,
            parakeetInstalled: ParakeetModel.isInstalled,
            falaDanWhisperModels: FalaDanPaths.whisperModels.path,
            whisperModel: FalaDanPaths.whisperModel.path,
            whisperModelInstalled: FileManager.default.fileExists(atPath: FalaDanPaths.whisperModel.path),
            whisperVADModel: FalaDanPaths.whisperVADModel.path,
            whisperVADModelInstalled: FileManager.default.fileExists(atPath: FalaDanPaths.whisperVADModel.path),
            claudeSkills: FalaDanPaths.claudeSkills.path,
            claudeSkill: FalaDanPaths.coreSkillClaudeInstall.path,
            codexSkills: FalaDanPaths.codexSkills.path,
            codexSkill: FalaDanPaths.coreSkillCodexInstall.path
        )

        if emitJSON {
            do {
                Console.out(try JSONPrinter.string(from: output))
                return 0
            } catch {
                Console.error(error.localizedDescription)
                return 1
            }
        }

        Console.out(
            """
            FalaDan paths

            Executable: \(output.executable)
            FluidAudio models: \(output.fluidAudioModels)
            Parakeet: \(status(output.parakeetInstalled)) \(output.parakeet)
            FalaDan Whisper models: \(output.falaDanWhisperModels)
            Whisper model: \(status(output.whisperModelInstalled)) \(output.whisperModel)
            Whisper VAD model: \(status(output.whisperVADModelInstalled)) \(output.whisperVADModel)
            Claude skills: \(output.claudeSkills)
            Claude discovery skill: \(output.claudeSkill)
            Codex skills: \(output.codexSkills)
            Codex discovery skill: \(output.codexSkill)
            """
        )
        return 0
    }

    private static func printHelp() {
        Console.out(
            """
            Usage:
              faladancli paths [--json]
            """
        )
    }

    private static func status(_ installed: Bool) -> String {
        installed ? "[installed]" : "[missing]"
    }
}
