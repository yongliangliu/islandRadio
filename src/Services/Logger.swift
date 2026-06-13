import Foundation

/// Global log function that writes to stderr (visible in terminal)
/// and also to a log file for debugging.
func appLog(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] \(message)\n"
    // Write to stderr
    FileHandle.standardError.write(Data(line.utf8))
    // Also append to log file
    let logPath = "/tmp/islandradio.log"
    if let fh = FileHandle(forWritingAtPath: logPath) {
        fh.seekToEndOfFile()
        fh.write(Data(line.utf8))
        fh.closeFile()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: Data(line.utf8))
    }
}
