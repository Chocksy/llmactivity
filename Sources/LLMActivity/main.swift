import Foundation
if CommandLine.arguments.contains("--parsecheck") { exit(runParseCheck()) }
if CommandLine.arguments.contains("--dump") { exit(runDump()) }
print("llmactivity")
