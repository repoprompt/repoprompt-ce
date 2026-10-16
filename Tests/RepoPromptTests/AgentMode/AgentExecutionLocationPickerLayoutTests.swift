import AppKit
@testable import RepoPromptApp
import SwiftUI
import XCTest

@MainActor
final class AgentExecutionLocationPickerLayoutTests: XCTestCase {
    private enum State: CaseIterable {
        case loading
        case populated
        case empty
        case error
    }

    func testPickerRegionKeepsStableOuterSizeAcrossLoadingPopulatedEmptyAndError() {
        XCTAssertEqual(AgentExecutionLocationPickerLayout.popoverWidth(for: .normal), 300, accuracy: 0.01)
        XCTAssertEqual(AgentExecutionLocationPickerLayout.rowsHeight(for: .normal), 288, accuracy: 0.01)
        XCTAssertEqual(AgentExecutionLocationPickerLayout.popoverWidth(for: .extraLarge), 360, accuracy: 0.01)
        XCTAssertEqual(AgentExecutionLocationPickerLayout.rowsHeight(for: .extraLarge), 360, accuracy: 0.01)

        for preset in FontScalePreset.allCases {
            let expectedSize = CGSize(
                width: AgentExecutionLocationPickerLayout.popoverWidth(for: preset) - 16,
                height: AgentExecutionLocationPickerLayout.rowsHeight(for: preset)
            )
            var referenceSize: CGSize?
            for state in State.allCases {
                let measuredSize = measuredSize(for: state, preset: preset)
                XCTAssertEqual(measuredSize.width, expectedSize.width, accuracy: 1.0, "\(preset) \(state) width drifted from the configured region")
                XCTAssertEqual(measuredSize.height, expectedSize.height, accuracy: 1.0, "\(preset) \(state) height drifted from the configured region")
                if let referenceSize {
                    XCTAssertEqual(measuredSize.width, referenceSize.width, accuracy: 0.5, "\(preset) \(state) width changed relative to loading")
                    XCTAssertEqual(measuredSize.height, referenceSize.height, accuracy: 0.5, "\(preset) \(state) height changed relative to loading")
                } else {
                    referenceSize = measuredSize
                }
            }
        }
    }

    private func measuredSize(for state: State, preset: FontScalePreset) -> CGSize {
        let hostingView = NSHostingView(
            rootView: AgentExecutionLocationPickerRegion(
                width: AgentExecutionLocationPickerLayout.popoverWidth(for: preset) - 16,
                height: AgentExecutionLocationPickerLayout.rowsHeight(for: preset)
            ) {
                stateContent(for: state)
            }
        )
        hostingView.layoutSubtreeIfNeeded()
        return hostingView.fittingSize
    }

    @ViewBuilder
    private func stateContent(for state: State) -> some View {
        switch state {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        case .populated:
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(0 ..< 8, id: \.self) { index in
                        Text("Existing worktree \(index)")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    }
                }
            }
        case .empty:
            Text("No other worktrees available")
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
        case .error:
            Text("Unable to load existing worktrees because the repository is temporarily unavailable.")
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
        }
    }
}
