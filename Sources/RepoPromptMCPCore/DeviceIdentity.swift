import Foundation

struct DeviceIdentity {
    static let shared = DeviceIdentity()
    let id: String

    private init() {
        let fm = FileManager.default
        let baseDir = fm.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
            .appendingPathComponent("com.repoprompt", isDirectory: true)
        let fileURL = baseDir.appendingPathComponent("device-id")

        #if DEBUG
            fputs("CLI DeviceIdentity: Looking for device ID at: \(fileURL.path)\n", stderr)
        #endif

        try? fm.createDirectory(
            at: baseDir,
            withIntermediateDirectories: true
        )

        if let data = try? Data(contentsOf: fileURL),
           let str = String(data: data, encoding: .utf8)?
           .trimmingCharacters(in: .whitespacesAndNewlines),
           !str.isEmpty
        {
            id = str
            #if DEBUG
                fputs("CLI DeviceIdentity: Loaded existing device ID: \(str)\n", stderr)
            #endif
        } else {
            let newID = UUID().uuidString
            try? newID.data(using: .utf8)?
                .write(to: fileURL, options: [.atomic])
            id = newID
            #if DEBUG
                fputs("CLI DeviceIdentity: Created new device ID: \(newID)\n", stderr)
            #endif
        }
    }
}
