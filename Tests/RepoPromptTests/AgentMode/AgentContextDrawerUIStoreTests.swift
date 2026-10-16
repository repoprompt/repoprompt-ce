import Combine
@testable import RepoPromptApp
import XCTest

@MainActor
final class AgentContextDrawerUIStoreTests: XCTestCase {
    func testPresentationStateDefaultsTogglesAndRetainsRuntimeValues() {
        let store = AgentContextDrawerUIStore()

        XCTAssertFalse(store.isPresented)
        XCTAssertFalse(store.presentation.isPresented)
        XCTAssertEqual(store.activeTab, .files)
        XCTAssertEqual(store.detail.activeTab, .files)
        XCTAssertEqual(store.filesSubtab, .files)
        XCTAssertEqual(store.detail.filesSubtab, .files)
        XCTAssertEqual(store.fileFilterText, "")
        XCTAssertEqual(store.detail.fileFilterText, "")
        XCTAssertEqual(store.selectionSort, .tokensDescending)
        XCTAssertEqual(store.detail.selectionSort, .tokensDescending)
        XCTAssertEqual(AgentContextDrawerUIStore.SelectionSort.allCases.map(\.label), [
            "Name A→Z",
            "Name Z→A",
            "Tokens ↓",
            "Tokens ↑"
        ])

        store.open()
        XCTAssertTrue(store.isPresented)
        XCTAssertTrue(store.presentation.isPresented)
        XCTAssertEqual(store.activeTab, .files)

        store.activeTab = .builder
        store.filesSubtab = .codemaps
        store.fileFilterText = "Sources"
        store.selectionSort = .nameAscending
        store.close()
        store.open()
        XCTAssertTrue(store.isPresented)
        XCTAssertEqual(store.activeTab, .builder)
        XCTAssertEqual(store.detail.activeTab, .builder)
        XCTAssertEqual(store.filesSubtab, .codemaps)
        XCTAssertEqual(store.detail.filesSubtab, .codemaps)
        XCTAssertEqual(store.fileFilterText, "Sources")
        XCTAssertEqual(store.detail.fileFilterText, "Sources")
        XCTAssertEqual(store.selectionSort, .nameAscending)
        XCTAssertEqual(store.detail.selectionSort, .nameAscending)

        store.toggle(tab: .prompt)
        XCTAssertTrue(store.isPresented)
        XCTAssertEqual(store.activeTab, .prompt)

        store.toggle(tab: .prompt)
        XCTAssertFalse(store.isPresented)
        XCTAssertEqual(store.activeTab, .prompt)

        let publicationStore = AgentContextDrawerUIStore()
        var cancellables = Set<AnyCancellable>()
        var presentationPublicationCount = 0
        var detailPublicationCount = 0
        publicationStore.presentation.objectWillChange
            .sink { presentationPublicationCount += 1 }
            .store(in: &cancellables)
        publicationStore.detail.objectWillChange
            .sink { detailPublicationCount += 1 }
            .store(in: &cancellables)

        publicationStore.detail.fileFilterText = "Sources"
        publicationStore.detail.filesSubtab = .codemaps
        publicationStore.detail.selectionSort = .nameDescending
        XCTAssertEqual(presentationPublicationCount, 0)
        XCTAssertEqual(detailPublicationCount, 3)

        publicationStore.open()
        XCTAssertEqual(presentationPublicationCount, 1)
        XCTAssertEqual(detailPublicationCount, 3)
    }

    func testSelectionSortOrdersRowsDeterministically() throws {
        let rootA = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let rootB = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let alphaAID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000101"))
        let alphaZID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000102"))
        let betaID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000103"))
        let omegaRootBID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000104"))
        let omegaRootAID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000105"))
        let gammaID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000106"))
        let unknownID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000107"))
        let zeroID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000108"))
        let rows = [
            makeRow(
                fileID: omegaRootBID,
                rootID: rootB,
                name: "Omega.swift",
                path: "Sources/Omega.swift",
                tokens: 1
            ),
            makeRow(
                fileID: alphaAID,
                rootID: rootA,
                name: "Alpha.swift",
                path: "Sources/A/Alpha.swift",
                tokens: 9
            ),
            makeRow(
                fileID: betaID,
                rootID: rootA,
                name: "Beta.swift",
                path: "Sources/Beta.swift",
                kind: .codemap,
                mode: .codemap,
                tokens: 20
            ),
            makeRow(
                fileID: alphaZID,
                rootID: rootA,
                name: "Alpha.swift",
                path: "Sources/Z/Alpha.swift",
                tokens: 4
            ),
            makeRow(
                fileID: omegaRootAID,
                rootID: rootA,
                name: "Omega.swift",
                path: "Sources/Omega.swift",
                tokens: 1
            ),
            makeRow(
                fileID: gammaID,
                rootID: rootB,
                name: "Gamma.swift",
                path: "Sources/Gamma.swift",
                tokens: 20
            ),
            makeRow(
                fileID: unknownID,
                rootID: rootA,
                name: "Delta.swift",
                path: "Sources/Delta.swift",
                metrics: .unknown
            ),
            makeRow(
                fileID: zeroID,
                rootID: rootA,
                name: "Zeta.swift",
                path: "Sources/Zeta.swift",
                tokens: 0
            )
        ]

        XCTAssertEqual(
            sortedPaths(rows, by: .tokensDescending),
            [
                "Sources/Beta.swift",
                "Sources/Gamma.swift",
                "Sources/A/Alpha.swift",
                "Sources/Z/Alpha.swift",
                "Sources/Omega.swift@00000000-0000-0000-0000-000000000001",
                "Sources/Omega.swift@00000000-0000-0000-0000-000000000002",
                "Sources/Delta.swift",
                "Sources/Zeta.swift"
            ]
        )
        XCTAssertEqual(
            sortedPaths(rows, by: .tokensAscending),
            [
                "Sources/Delta.swift",
                "Sources/Zeta.swift",
                "Sources/Omega.swift@00000000-0000-0000-0000-000000000001",
                "Sources/Omega.swift@00000000-0000-0000-0000-000000000002",
                "Sources/Z/Alpha.swift",
                "Sources/A/Alpha.swift",
                "Sources/Beta.swift",
                "Sources/Gamma.swift"
            ]
        )
        XCTAssertEqual(
            sortedPaths(rows, by: .nameAscending),
            [
                "Sources/A/Alpha.swift",
                "Sources/Z/Alpha.swift",
                "Sources/Beta.swift",
                "Sources/Delta.swift",
                "Sources/Gamma.swift",
                "Sources/Omega.swift@00000000-0000-0000-0000-000000000001",
                "Sources/Omega.swift@00000000-0000-0000-0000-000000000002",
                "Sources/Zeta.swift"
            ]
        )
        XCTAssertEqual(
            sortedPaths(rows, by: .nameDescending),
            [
                "Sources/Zeta.swift",
                "Sources/Omega.swift@00000000-0000-0000-0000-000000000001",
                "Sources/Omega.swift@00000000-0000-0000-0000-000000000002",
                "Sources/Gamma.swift",
                "Sources/Delta.swift",
                "Sources/Beta.swift",
                "Sources/Z/Alpha.swift",
                "Sources/A/Alpha.swift"
            ]
        )
    }

    private func sortedPaths(
        _ rows: [AgentContextExportRow],
        by sort: AgentContextDrawerUIStore.SelectionSort
    ) -> [String] {
        sort.sortedRows(rows).map { row in
            if row.displayPath == "Sources/Omega.swift" {
                return "\(row.displayPath)@\(row.rootID.uuidString)"
            }
            return row.displayPath
        }
    }

    private func makeRow(
        fileID: UUID,
        rootID: UUID,
        name: String,
        path: String,
        kind: AgentContextExportRow.Kind = .full,
        mode: PromptFileEntryMode = .fullFile,
        tokens: Int
    ) -> AgentContextExportRow {
        makeRow(
            fileID: fileID,
            rootID: rootID,
            name: name,
            path: path,
            kind: kind,
            mode: mode,
            metrics: .known(tokenCount: tokens, tokenPercentage: 0, lineCount: nil)
        )
    }

    private func makeRow(
        fileID: UUID,
        rootID: UUID,
        name: String,
        path: String,
        kind: AgentContextExportRow.Kind = .full,
        mode: PromptFileEntryMode = .fullFile,
        metrics: AgentContextExportRow.Metrics
    ) -> AgentContextExportRow {
        AgentContextExportRow(
            id: ResolvedPromptFileEntryID(fileID: fileID, mode: mode, lineRanges: nil),
            kind: kind,
            rootID: rootID,
            relativePath: path,
            displayPath: path,
            displayName: name,
            directoryDisplay: nil,
            lineRanges: nil,
            metrics: metrics,
            canRemove: true
        )
    }
}
