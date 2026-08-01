import Darwin
import Foundation

@main
struct FalaDanCLI {
    static func main() async {
        let status = await CLI.run(arguments: Array(CommandLine.arguments.dropFirst()))
        Darwin.exit(status)
    }
}

