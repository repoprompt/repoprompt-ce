import Foundation
import SwiftUI

func agentContextDrawerGeneratedAnswerPopoverUserInfo(
    windowID: Int,
    route: ContextBuilderGeneratedAnswerRoute
) -> [AnyHashable: Any]? {
    contextBuilderOraclePopoverUserInfo(
        openContext: AgentOracleOpenContext(
            windowID: windowID,
            workspaceID: route.workspaceID,
            tabID: route.tabID,
            chatID: route.chatID
        ),
        chatID: route.chatID
    )
}

struct AgentContextDrawerBuilderTab: View {
    @ObservedObject var contextBuilderAgentVM: ContextBuilderAgentViewModel
    @ObservedObject var oracleViewModel: OracleViewModel
    let windowID: Int

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical, showsIndicators: true) {
                ContextBuilderAgentView(
                    viewModel: contextBuilderAgentVM,
                    oracleViewModel: oracleViewModel,
                    windowID: windowID,
                    availableWidth: max(280, geometry.size.width - 40),
                    openGeneratedAnswerChat: openGeneratedAnswerChat(route:)
                )
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func openGeneratedAnswerChat(route: ContextBuilderGeneratedAnswerRoute) {
        guard let userInfo = agentContextDrawerGeneratedAnswerPopoverUserInfo(
            windowID: windowID,
            route: route
        ) else { return }
        NotificationCenter.default.post(name: .showAgentOraclePopover, object: nil, userInfo: userInfo)
    }
}
