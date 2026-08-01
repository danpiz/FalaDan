import Foundation
@preconcurrency import FluidAudio

struct ModelsStatusOutput: Encodable {
    let ok: Bool
    let parakeet: ModelStatusOutput
    let whisper: WhisperModelStatusOutput
}

struct ModelStatusOutput: Encodable {
    let installed: Bool
    let path: String
    let installCommand: String

    enum CodingKeys: String, CodingKey {
        case installed
        case path
        case installCommand = "install_command"
    }
}

struct WhisperModelStatusOutput: Encodable {
    let installed: Bool
    let path: String
    let vadInstalled: Bool
    let vadPath: String
    let installCommand: String

    enum CodingKeys: String, CodingKey {
        case installed
        case path
        case vadInstalled = "vad_installed"
        case vadPath = "vad_path"
        case installCommand = "install_command"
    }
}

struct ModelInstallOutput: Encodable {
    let ok: Bool
    let model: String
    let changed: Bool
    let status: ModelsStatusOutput
}

enum ModelsCommand {
    static func run(arguments: [String]) async -> Int32 {
        guard let subcommand = arguments.first else {
            return status(arguments: [])
        }

        let rest = Array(arguments.dropFirst())

        switch subcommand {
        case "-h", "--help":
            printHelp()
            return 0
        case "status":
            return status(arguments: rest)
        case "install":
            return await install(arguments: rest)
        default:
            Console.error("Unknown models command: \(subcommand)")
            Console.error("Run `faladancli models --help` for usage.")
            return 2
        }
    }

    private static func status(arguments: [String]) -> Int32 {
        let emitJSON = arguments.contains("--json")
        let unknown = arguments.first { $0 != "--json" }
        if let unknown {
            Console.error("Unknown models status option: \(unknown)")
            return 2
        }

        let output = makeStatus()
        if emitJSON {
            do {
                Console.out(try JSONPrinter.string(from: output))
                return 0
            } catch {
                Console.error(error.localizedDescription)
                return 1
            }
        }

        printStatus(output)
        return 0
    }

    private static func install(arguments: [String]) async -> Int32 {
        guard let model = arguments.first else {
            Console.error("Missing model. Expected parakeet or whisper.")
            Console.error("Examples:")
            Console.error("  faladancli models install parakeet")
            Console.error("  faladancli models install whisper")
            return 2
        }

        let rest = Array(arguments.dropFirst())
        let emitJSON = rest.contains("--json")
        let quiet = rest.contains("--quiet") || emitJSON
        let unknown = rest.first { $0 != "--json" && $0 != "--quiet" }
        if let unknown {
            Console.error("Unknown models install option: \(unknown)")
            return 2
        }

        do {
            let before = makeStatus()
            switch model {
            case "parakeet":
                if !quiet {
                    Console.error(before.parakeet.installed
                        ? "Parakeet is already installed; verifying \(ParakeetModel.modelName)..."
                        : "Downloading \(ParakeetModel.modelName) to \(ParakeetModel.directory.path)...")
                }
                _ = try await AsrModels.downloadAndLoad(version: ParakeetModel.version)
            case "whisper":
                if !quiet {
                    Console.error(before.whisper.installed && before.whisper.vadInstalled
                        ? "Whisper is already installed; verifying local files..."
                        : "Downloading Whisper models to \(FalaDanPaths.whisperModels.path)...")
                }
                try await WhisperCLITranscriber.installModels(quiet: quiet)
            default:
                Console.error("Unknown model: \(model). Expected parakeet or whisper.")
                return 2
            }

            let after = makeStatus()
            let changed = didInstallChange(model: model, before: before, after: after)
            if emitJSON {
                let output = ModelInstallOutput(ok: true, model: model, changed: changed, status: after)
                Console.out(try JSONPrinter.string(from: output))
            } else {
                Console.out("\(displayName(for: model)) ready.")
                printStatus(after)
            }
            return 0
        } catch {
            Console.error(error.localizedDescription)
            return 1
        }
    }

    static func makeStatus() -> ModelsStatusOutput {
        let parakeetInstalled = ParakeetModel.isInstalled
        let whisperInstalled = FileManager.default.fileExists(atPath: FalaDanPaths.whisperModel.path)
        let whisperVADInstalled = FileManager.default.fileExists(atPath: FalaDanPaths.whisperVADModel.path)

        return ModelsStatusOutput(
            ok: parakeetInstalled,
            parakeet: ModelStatusOutput(
                installed: parakeetInstalled,
                path: ParakeetModel.directory.path,
                installCommand: "faladancli models install parakeet"
            ),
            whisper: WhisperModelStatusOutput(
                installed: whisperInstalled,
                path: FalaDanPaths.whisperModel.path,
                vadInstalled: whisperVADInstalled,
                vadPath: FalaDanPaths.whisperVADModel.path,
                installCommand: "faladancli models install whisper"
            )
        )
    }

    private static func printStatus(_ output: ModelsStatusOutput) {
        Console.out(
            """
            FalaDan models

            \(status(output.parakeet.installed)) Parakeet: \(output.parakeet.path)
            \(status(output.whisper.installed)) Whisper: \(output.whisper.path)
            \(status(output.whisper.vadInstalled)) Whisper VAD: \(output.whisper.vadPath)

            Install:
              faladancli models install parakeet
              faladancli models install whisper
            """
        )
    }

    private static func didInstallChange(
        model: String,
        before: ModelsStatusOutput,
        after: ModelsStatusOutput
    ) -> Bool {
        switch model {
        case "parakeet":
            return before.parakeet.installed != after.parakeet.installed
        case "whisper":
            return before.whisper.installed != after.whisper.installed
                || before.whisper.vadInstalled != after.whisper.vadInstalled
        default:
            return false
        }
    }

    private static func displayName(for model: String) -> String {
        switch model {
        case "parakeet": return "Parakeet"
        case "whisper": return "Whisper"
        default: return model
        }
    }

    private static func status(_ installed: Bool) -> String {
        installed ? "[installed]" : "[missing]"
    }

    private static func printHelp() {
        Console.out(
            """
            Usage:
              faladancli models
              faladancli models status [--json]
              faladancli models install <parakeet|whisper> [--json] [--quiet]

            Examples:
              faladancli models status
              faladancli models install parakeet
              faladancli models install whisper
            """
        )
    }
}
