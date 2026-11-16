import Foundation

/// One binary, three modes: the menu bar app, an MCP server (`--mcp`), and a CLI
/// (`netmon <command>`, usually via a symlink named `netmon`).
@main
enum Entry {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        let invokedAsCLI = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent == "netmon"

        if args.first == "--mcp" {
            MCPServer.run()
        } else if invokedAsCLI || args.first.map(CLI.commands.contains) == true {
            CLI.run(args)
        } else {
            NetMonApp.main()
        }
    }
}
