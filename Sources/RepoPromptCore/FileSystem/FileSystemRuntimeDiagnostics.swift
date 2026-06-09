import Foundation

package struct FileSystemDiagnosticContext: Equatable {
    package let correlationID: UUID

    package init(correlationID: UUID = UUID()) {
        self.correlationID = correlationID
    }
}
