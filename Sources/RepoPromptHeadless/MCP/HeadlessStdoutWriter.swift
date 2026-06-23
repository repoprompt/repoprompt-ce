import Foundation

actor HeadlessStdoutWriter {
    private let writeHandler: (Data) -> Void

    init(fileHandle: FileHandle = .standardOutput) {
        writeHandler = { data in
            fileHandle.write(data)
        }
    }

    init(writeHandler: @escaping (Data) -> Void) {
        self.writeHandler = writeHandler
    }

    func write(_ data: Data) {
        guard !data.isEmpty else {
            return
        }
        var framed = data
        framed.append(0x0A)
        writeHandler(framed)
    }
}
