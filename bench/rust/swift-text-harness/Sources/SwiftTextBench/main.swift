import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    FileHandle.standardError.write(Data("usage: swift-text-bench <probe|tables|oracle|parity|bench> ...\n".utf8))
    exit(2)
}

switch command {
case "probe":
    Probe.run(arguments.count > 1 ? arguments[1] : "misc")
case "tables":
    do {
        try Tablegen.run(outPath: arguments.count > 1 ? arguments[1] : "tables.rs")
    } catch {
        FileHandle.standardError.write(Data("tables: \(error)\n".utf8))
        exit(1)
    }
case "parity", "bench", "oracle":
    do {
        let parsed = Arguments(Array(arguments.dropFirst()))
        switch command {
        case "parity": try ParityCommand.run(parsed)
        case "oracle": try OracleCommand.run(parsed)
        default: try BenchCommand.run(parsed)
        }
    } catch {
        FileHandle.standardError.write(Data("\(command): \(error)\n".utf8))
        exit(1)
    }
default:
    FileHandle.standardError.write(Data("unknown command \(command)\n".utf8))
    exit(2)
}
