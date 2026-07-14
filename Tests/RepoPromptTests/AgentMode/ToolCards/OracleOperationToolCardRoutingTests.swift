@testable import RepoPromptApp
import XCTest

final class OracleOperationToolCardRoutingTests: XCTestCase {
    func testContextBuilderSelectsExactPlanOrReviewChatID() throws {
        let planDTO = try contextBuilderDTO(responseType: "plan")
        let questionDTO = try contextBuilderDTO(responseType: "question")
        let reviewDTO = try contextBuilderDTO(responseType: "review")
        let normalizedPlanDTO = try contextBuilderDTO(responseType: "  PlAn\n")
        let normalizedQuestionDTO = try contextBuilderDTO(responseType: "\tQuEsTiOn ")
        let normalizedReviewDTO = try contextBuilderDTO(responseType: " ReViEw ")

        XCTAssertEqual(contextBuilderFollowUpChatID(for: planDTO), "plan-chat")
        XCTAssertEqual(contextBuilderFollowUpChatID(for: questionDTO), "plan-chat")
        XCTAssertEqual(contextBuilderFollowUpChatID(for: reviewDTO), "review-chat")
        XCTAssertEqual(contextBuilderFollowUpChatID(for: normalizedPlanDTO), "plan-chat")
        XCTAssertEqual(contextBuilderFollowUpChatID(for: normalizedQuestionDTO), "plan-chat")
        XCTAssertEqual(contextBuilderFollowUpChatID(for: normalizedReviewDTO), "review-chat")

        let tabID = UUID()
        let workspaceID = UUID()
        let openContext = AgentOracleOpenContext(
            windowID: 42,
            workspaceID: workspaceID,
            tabID: tabID,
            chatID: "ambient-chat"
        )
        let userInfo = try XCTUnwrap(contextBuilderOraclePopoverUserInfo(
            openContext: openContext,
            chatID: contextBuilderFollowUpChatID(for: reviewDTO)
        ))

        XCTAssertEqual(userInfo["windowID"] as? Int, 42)
        XCTAssertEqual(userInfo["workspaceID"] as? UUID, workspaceID)
        XCTAssertEqual(userInfo["tabID"] as? UUID, tabID)
        XCTAssertEqual(userInfo["chatID"] as? String, "review-chat")
    }

    func testContextBuilderOperationRoutingRejectsMissingOrBlankChatIDWithoutAmbientFallback() {
        let openContext = AgentOracleOpenContext(
            windowID: 42,
            workspaceID: UUID(),
            tabID: UUID(),
            chatID: "ambient-chat"
        )

        XCTAssertNil(contextBuilderOraclePopoverUserInfo(openContext: openContext, chatID: nil))
        XCTAssertNil(contextBuilderOraclePopoverUserInfo(openContext: openContext, chatID: "   \n"))
        XCTAssertNil(contextBuilderOraclePopoverUserInfo(
            openContext: AgentOracleOpenContext(windowID: 42, workspaceID: nil, tabID: UUID()),
            chatID: "exact-chat"
        ))
        XCTAssertNil(contextBuilderOraclePopoverUserInfo(
            openContext: AgentOracleOpenContext(windowID: 42, workspaceID: UUID(), tabID: nil),
            chatID: "exact-chat"
        ))
    }

    func testDrawerBuilderGeneratedAnswerRoutingAndTooltipsUseAnswerWording() throws {
        let route = ContextBuilderGeneratedAnswerRoute(
            workspaceID: UUID(),
            tabID: UUID(),
            chatID: "  generated-answer-chat  "
        )
        let changedWorkspaceID = UUID()
        let changedTabID = UUID()
        XCTAssertNotEqual(changedWorkspaceID, route.workspaceID)
        XCTAssertNotEqual(changedTabID, route.tabID)

        let ready = ContextBuilderPlanStatus.ready(route: route, previewText: "Generated answer")
        var callbackRoute: ContextBuilderGeneratedAnswerRoute?
        if case let .ready(readyRoute, _) = ready {
            let openGeneratedAnswerChat: (ContextBuilderGeneratedAnswerRoute) -> Void = {
                callbackRoute = $0
            }
            openGeneratedAnswerChat(readyRoute)
        }
        XCTAssertEqual(callbackRoute, route)

        let userInfo = try XCTUnwrap(agentContextDrawerGeneratedAnswerPopoverUserInfo(
            windowID: 8,
            route: route
        ))

        XCTAssertEqual(Set(userInfo.keys.compactMap { $0 as? String }), [
            "windowID",
            "workspaceID",
            "tabID",
            "chatID"
        ])
        XCTAssertEqual(userInfo["windowID"] as? Int, 8)
        XCTAssertEqual(userInfo["workspaceID"] as? UUID, route.workspaceID)
        XCTAssertEqual(userInfo["tabID"] as? UUID, route.tabID)
        XCTAssertEqual(userInfo["chatID"] as? String, "generated-answer-chat")
        XCTAssertEqual(AgentOraclePopoverRoute(notificationUserInfo: userInfo)?.chatID, "generated-answer-chat")

        let tooltips = [
            ContextBuilderGeneratedAnswerActionText.useAsPromptTooltip,
            ContextBuilderGeneratedAnswerActionText.copyTooltip,
            ContextBuilderGeneratedAnswerActionText.previewTooltip,
            ContextBuilderGeneratedAnswerActionText.viewInChatTooltip
        ]
        XCTAssertEqual(tooltips, [
            "Use the generated answer as your prompt",
            "Copy answer to clipboard",
            "Preview the generated answer",
            "Open answer in chat view"
        ])
        XCTAssertFalse(tooltips.contains { $0.localizedCaseInsensitiveContains("plan") })
    }

    func testOracleLatestPopoverRouteOmitsChatIDAndPreservesScope() throws {
        let workspaceID = UUID()
        let contextTabID = UUID()
        let overrideTabID = UUID()
        let openContext = AgentOracleOpenContext(
            windowID: 42,
            workspaceID: workspaceID,
            tabID: contextTabID,
            chatID: "ambient-chat"
        )
        let route = try XCTUnwrap(AgentOracleLatestPopoverRoute(
            openContext: openContext,
            tabID: overrideTabID
        ))

        XCTAssertEqual(route.windowID, 42)
        XCTAssertEqual(route.workspaceID, workspaceID)
        XCTAssertEqual(route.tabID, overrideTabID)

        let userInfo = route.notificationUserInfo
        XCTAssertEqual(userInfo["windowID"] as? Int, 42)
        XCTAssertEqual(userInfo["workspaceID"] as? UUID, workspaceID)
        XCTAssertEqual(userInfo["tabID"] as? UUID, overrideTabID)
        XCTAssertEqual(userInfo["route"] as? String, "latest")
        XCTAssertNil(userInfo["chatID"])
        XCTAssertEqual(AgentOracleLatestPopoverRoute(notificationUserInfo: userInfo), route)
        XCTAssertNil(AgentOraclePopoverRoute(notificationUserInfo: userInfo))

        XCTAssertNil(AgentOracleLatestPopoverRoute(openContext: nil))
        XCTAssertNil(AgentOracleLatestPopoverRoute(
            openContext: AgentOracleOpenContext(windowID: 42, workspaceID: nil, tabID: contextTabID)
        ))
        XCTAssertNil(AgentOracleLatestPopoverRoute(
            openContext: AgentOracleOpenContext(windowID: 42, workspaceID: workspaceID, tabID: nil)
        ))
        XCTAssertNil(AgentOracleLatestPopoverRoute(notificationUserInfo: [
            "windowID": 42,
            "workspaceID": workspaceID,
            "tabID": contextTabID
        ]))
        XCTAssertNil(AgentOracleLatestPopoverRoute(notificationUserInfo: [
            "windowID": 42,
            "workspaceID": workspaceID,
            "tabID": contextTabID,
            "route": "other"
        ]))
        XCTAssertNil(AgentOracleLatestPopoverRoute(notificationUserInfo: [
            "windowID": 42,
            "workspaceID": workspaceID,
            "tabID": contextTabID,
            "route": "latest",
            "chatID": "exact-chat"
        ]))
    }

    func testOraclePopoverRoutePreservesNotificationTypesAndCompatibilityDecoding() throws {
        let workspaceID = UUID()
        let contextTabID = UUID()
        let overrideTabID = UUID()
        let openContext = AgentOracleOpenContext(
            windowID: 42,
            workspaceID: workspaceID,
            tabID: contextTabID,
            chatID: "ambient-chat"
        )
        let route = try XCTUnwrap(AgentOraclePopoverRoute(
            openContext: openContext,
            chatID: "  exact-short-id  ",
            tabID: overrideTabID
        ))

        XCTAssertEqual(route.windowID, 42)
        XCTAssertEqual(route.workspaceID, workspaceID)
        XCTAssertEqual(route.tabID, overrideTabID)
        XCTAssertEqual(route.chatID, "exact-short-id")

        let userInfo = route.notificationUserInfo
        XCTAssertEqual(userInfo["windowID"] as? Int, 42)
        XCTAssertEqual(userInfo["workspaceID"] as? UUID, workspaceID)
        XCTAssertEqual(userInfo["tabID"] as? UUID, overrideTabID)
        XCTAssertEqual(userInfo["chatID"] as? String, "exact-short-id")
        XCTAssertEqual(AgentOraclePopoverRoute(notificationUserInfo: userInfo), route)

        let stringCompatibleRoute = try XCTUnwrap(AgentOraclePopoverRoute(notificationUserInfo: [
            "windowID": 7,
            "workspaceID": workspaceID.uuidString,
            "tabID": contextTabID.uuidString,
            "chatID": "  short-chat  ",
            "extra": true
        ]))
        XCTAssertEqual(stringCompatibleRoute.workspaceID, workspaceID)
        XCTAssertEqual(stringCompatibleRoute.tabID, contextTabID)
        XCTAssertEqual(stringCompatibleRoute.chatID, "short-chat")

        let chatUUID = UUID()
        let uuidChatRoute = try XCTUnwrap(AgentOraclePopoverRoute(notificationUserInfo: [
            "windowID": 7,
            "workspaceID": workspaceID,
            "tabID": contextTabID,
            "chatID": chatUUID
        ]))
        XCTAssertEqual(uuidChatRoute.chatID, chatUUID.uuidString)
    }

    func testOraclePopoverRouteRejectsMissingMalformedAndAmbientFallbackInputs() {
        let workspaceID = UUID()
        let tabID = UUID()
        let openContext = AgentOracleOpenContext(
            windowID: 42,
            workspaceID: workspaceID,
            tabID: tabID,
            chatID: "ambient-chat"
        )

        XCTAssertNil(AgentOraclePopoverRoute(openContext: nil, chatID: "exact-chat"))
        XCTAssertNil(AgentOraclePopoverRoute(
            openContext: AgentOracleOpenContext(windowID: 42, workspaceID: nil, tabID: tabID),
            chatID: "exact-chat"
        ))
        XCTAssertNil(AgentOraclePopoverRoute(
            openContext: AgentOracleOpenContext(windowID: 42, workspaceID: workspaceID, tabID: nil),
            chatID: "exact-chat"
        ))
        XCTAssertNil(AgentOraclePopoverRoute(openContext: openContext, chatID: nil))
        XCTAssertNil(AgentOraclePopoverRoute(openContext: openContext, chatID: "  \n"))

        let valid: [AnyHashable: Any] = [
            "windowID": 42,
            "workspaceID": workspaceID,
            "tabID": tabID,
            "chatID": "exact-chat"
        ]
        XCTAssertNil(AgentOraclePopoverRoute(notificationUserInfo: nil))
        for key in ["windowID", "workspaceID", "tabID", "chatID"] {
            var missing = valid
            missing.removeValue(forKey: key)
            XCTAssertNil(AgentOraclePopoverRoute(notificationUserInfo: missing), key)
        }

        var malformed = valid
        malformed["windowID"] = "42"
        XCTAssertNil(AgentOraclePopoverRoute(notificationUserInfo: malformed))
        malformed = valid
        malformed["workspaceID"] = "not-a-uuid"
        XCTAssertNil(AgentOraclePopoverRoute(notificationUserInfo: malformed))
        malformed = valid
        malformed["tabID"] = 42
        XCTAssertNil(AgentOraclePopoverRoute(notificationUserInfo: malformed))
        malformed = valid
        malformed["chatID"] = "  \n"
        XCTAssertNil(AgentOraclePopoverRoute(notificationUserInfo: malformed))
        malformed = valid
        malformed["chatID"] = 42
        XCTAssertNil(AgentOraclePopoverRoute(notificationUserInfo: malformed))
    }

    func testDirectOracleResultRoutingRequiresExactResultChatID() throws {
        let tabID = UUID()
        let openContext = AgentOracleOpenContext(
            windowID: 7,
            workspaceID: UUID(),
            tabID: tabID,
            chatID: "ambient-chat"
        )
        let exactItem = toolResultItem(
            toolName: "ask_oracle",
            payload: ["chat_id": "  exact-result-chat  ", "mode": "review"]
        )
        let exactUserInfo = try XCTUnwrap(oracleToolResultPopoverUserInfo(
            item: exactItem,
            openContext: openContext
        ))

        XCTAssertEqual(exactUserInfo["windowID"] as? Int, 7)
        XCTAssertEqual(exactUserInfo["tabID"] as? UUID, tabID)
        XCTAssertEqual(exactUserInfo["chatID"] as? String, "exact-result-chat")

        let exactOracleSendUserInfo = oracleToolResultPopoverUserInfo(
            item: toolResultItem(
                toolName: "oracle_send",
                payload: ["chat_id": "exact-oracle-send-chat"]
            ),
            openContext: openContext
        )
        XCTAssertEqual(exactOracleSendUserInfo?["chatID"] as? String, "exact-oracle-send-chat")

        let malformedOptionalPayloadUserInfo = oracleToolResultPopoverUserInfo(
            item: toolResultItem(
                toolName: "ask_oracle",
                payload: ["chat_id": "exact-despite-malformed-diffs", "diffs": [["path": 42]]]
            ),
            openContext: openContext
        )
        XCTAssertEqual(
            malformedOptionalPayloadUserInfo?["chatID"] as? String,
            "exact-despite-malformed-diffs"
        )

        XCTAssertNil(oracleToolResultPopoverUserInfo(
            item: toolResultItem(toolName: "ask_oracle", payload: ["mode": "review"]),
            openContext: openContext
        ))
        XCTAssertNil(oracleToolResultPopoverUserInfo(
            item: toolResultItem(toolName: "ask_oracle", payload: ["chat_id": "\n  "]),
            openContext: openContext
        ))
        XCTAssertNil(oracleToolResultPopoverUserInfo(
            item: toolResultItem(toolName: "oracle_send", payload: ["chat_id": "   "]),
            openContext: openContext
        ))
    }

    func testOracleToolCallRoutingRequiresExactArgumentChatID() throws {
        let openContext = AgentOracleOpenContext(
            windowID: 9,
            workspaceID: UUID(),
            tabID: UUID(),
            chatID: "ambient-chat"
        )
        let exactItem = AgentChatItem(
            kind: .toolCall,
            text: "",
            toolName: "oracle_send",
            toolArgsJSON: jsonString(["chat_id": "  exact-call-chat  "])
        )
        let exactUserInfo = try XCTUnwrap(oracleToolCallPopoverUserInfo(
            item: exactItem,
            openContext: openContext
        ))

        XCTAssertEqual(exactUserInfo["chatID"] as? String, "exact-call-chat")

        let completedExactUserInfo = try XCTUnwrap(oracleToolCallPopoverUserInfo(
            item: AgentChatItem(
                kind: .toolCall,
                text: "",
                toolName: "ask_oracle",
                toolArgsJSON: jsonString(["message": "start a new chat"]),
                toolResultJSON: jsonString(["chat_id": "  exact-result-chat  ", "mode": "review"]),
                toolIsError: false
            ),
            openContext: openContext
        ))
        XCTAssertEqual(completedExactUserInfo["chatID"] as? String, "exact-result-chat")
        XCTAssertNil(completedExactUserInfo["route"])

        XCTAssertNil(oracleToolCallPopoverUserInfo(
            item: AgentChatItem(
                kind: .toolCall,
                text: "",
                toolName: "ask_oracle",
                toolArgsJSON: jsonString(["message": "start a new chat"]),
                toolResultJSON: jsonString(["status": "failed"]),
                toolIsError: true
            ),
            openContext: openContext
        ))

        let latestUserInfo = try XCTUnwrap(oracleToolCallPopoverUserInfo(
            item: AgentChatItem(
                kind: .toolCall,
                text: "",
                toolName: "ask_oracle",
                toolArgsJSON: jsonString(["message": "start a new chat"])
            ),
            openContext: openContext
        ))
        XCTAssertEqual(latestUserInfo["windowID"] as? Int, openContext.windowID)
        XCTAssertEqual(latestUserInfo["workspaceID"] as? UUID, openContext.workspaceID)
        XCTAssertEqual(latestUserInfo["tabID"] as? UUID, openContext.tabID)
        XCTAssertEqual(latestUserInfo["route"] as? String, "latest")
        XCTAssertNil(latestUserInfo["chatID"])
        XCTAssertNotNil(AgentOracleLatestPopoverRoute(notificationUserInfo: latestUserInfo))
        XCTAssertNil(AgentOraclePopoverRoute(notificationUserInfo: latestUserInfo))
        XCTAssertNil(oracleToolCallPopoverUserInfo(
            item: AgentChatItem(
                kind: .toolCall,
                text: "",
                toolName: "oracle_send",
                toolArgsJSON: jsonString(["chat_id": "\t "])
            ),
            openContext: openContext
        ))
        XCTAssertNil(oracleToolCallPopoverUserInfo(
            item: AgentChatItem(
                kind: .toolCall,
                text: "",
                toolName: "ask_oracle",
                toolArgsJSON: jsonString(["chatID": "camel-alias"])
            ),
            openContext: openContext
        ))
        XCTAssertNil(oracleToolCallPopoverUserInfo(
            item: AgentChatItem(
                kind: .toolCall,
                text: "",
                toolName: "ask_oracle",
                toolArgsJSON: jsonString(["message": "continue", "payload": ["chat_id": "nested"]])
            ),
            openContext: openContext
        ))
        XCTAssertNil(oracleToolCallPopoverUserInfo(
            item: AgentChatItem(
                kind: .toolCall,
                text: "",
                toolName: "ask_oracle",
                toolArgsJSON: "{bad json"
            ),
            openContext: openContext
        ))
        XCTAssertNil(oracleToolCallPopoverUserInfo(
            item: AgentChatItem(
                kind: .toolCall,
                text: "",
                toolName: "ask_oracle",
                toolArgsJSON: "  \n"
            ),
            openContext: openContext
        ))
        XCTAssertNil(oracleToolCallPopoverUserInfo(
            item: AgentChatItem(
                kind: .toolCall,
                text: "",
                toolName: "ask_oracle",
                toolArgsJSON: "[]"
            ),
            openContext: openContext
        ))
    }

    func testDirectOracleRoutingRejectsNestedAliasedAndConflictingChatIDs() {
        let openContext = AgentOracleOpenContext(
            windowID: 11,
            workspaceID: UUID(),
            tabID: UUID()
        )

        let rejectedPayloads: [[String: Any]] = [
            ["result": ["chat_id": "nested-only"]],
            ["chatID": "camel-only"],
            ["chat_id": 42],
            ["chat_id": "authoritative", "result": ["chat_id": "conflict"]],
            ["chat_id": "authoritative", "items": [["chatID": "conflict"]]]
        ]

        for payload in rejectedPayloads {
            XCTAssertNil(oracleToolResultPopoverUserInfo(
                item: toolResultItem(toolName: "ask_oracle", payload: payload),
                openContext: openContext
            ))
            XCTAssertNil(oracleToolCallPopoverUserInfo(
                item: AgentChatItem(
                    kind: .toolCall,
                    text: "",
                    toolName: "oracle_send",
                    toolArgsJSON: jsonString(payload)
                ),
                openContext: openContext
            ))
        }
    }

    func testAuthoritativeChatIDPolicyPreservesFailClosedRootRulesAcrossEntryPoints() {
        let acceptedPayloads: [([String: Any], String)] = [
            (["chat_id": "  exact-chat  "], "exact-chat"),
            (["chat_id": "exact-with-unrelated-data", "diffs": [["path": 42]]], "exact-with-unrelated-data")
        ]
        for (payload, expected) in acceptedPayloads {
            XCTAssertEqual(
                AgentOracleAuthoritativeChatIDPolicy.extract(fromRootObject: payload),
                expected
            )
            XCTAssertEqual(
                AgentOracleAuthoritativeChatIDPolicy.extract(fromSerializedJSON: jsonString(payload)),
                expected
            )
        }

        let rejectedPayloads: [[String: Any]] = [
            [:],
            ["chatID": "camel-only"],
            ["chat_id": "exact", "chatID": "alias"],
            ["chat_id": 42],
            ["chat_id": "  \n"],
            ["chat_id": "exact", "result": ["chat_id": "nested"]],
            ["chat_id": "exact", "items": [["chatID": "nested"]]]
        ]
        for payload in rejectedPayloads {
            XCTAssertNil(AgentOracleAuthoritativeChatIDPolicy.extract(fromRootObject: payload))
            XCTAssertNil(
                AgentOracleAuthoritativeChatIDPolicy.extract(fromSerializedJSON: jsonString(payload))
            )
        }

        XCTAssertNil(AgentOracleAuthoritativeChatIDPolicy.extract(fromSerializedJSON: nil))
        XCTAssertNil(AgentOracleAuthoritativeChatIDPolicy.extract(fromSerializedJSON: "  \n"))
        XCTAssertNil(AgentOracleAuthoritativeChatIDPolicy.extract(fromSerializedJSON: "not-json"))
        XCTAssertNil(AgentOracleAuthoritativeChatIDPolicy.extract(fromSerializedJSON: "null"))
        XCTAssertNil(AgentOracleAuthoritativeChatIDPolicy.extract(fromSerializedJSON: "42"))
        XCTAssertNil(AgentOracleAuthoritativeChatIDPolicy.extract(fromSerializedJSON: "[]"))
    }

    func testContextBuilderRoutingRejectsMismatchedOrUnknownResponseBranch() throws {
        let reviewWithPlanOnly = try XCTUnwrap(ToolJSON.decode(
            ToolResultDTOs.ContextBuilderDTO.self,
            from: jsonString([
                "status": "success",
                "response_type": "review",
                "plan": ["chat_id": "wrong-plan-chat", "mode": "plan"]
            ])
        ))
        let unknownWithPlan = try XCTUnwrap(ToolJSON.decode(
            ToolResultDTOs.ContextBuilderDTO.self,
            from: jsonString([
                "status": "success",
                "response_type": "clarify",
                "plan": ["chat_id": "wrong-plan-chat", "mode": "plan"]
            ])
        ))
        let planWithReviewOnly = try XCTUnwrap(ToolJSON.decode(
            ToolResultDTOs.ContextBuilderDTO.self,
            from: jsonString([
                "status": "success",
                "response_type": "plan",
                "review": ["chat_id": "wrong-review-chat", "mode": "review"]
            ])
        ))
        let missingResponseType = try XCTUnwrap(ToolJSON.decode(
            ToolResultDTOs.ContextBuilderDTO.self,
            from: jsonString([
                "status": "success",
                "plan": ["chat_id": "wrong-plan-chat", "mode": "plan"],
                "review": ["chat_id": "wrong-review-chat", "mode": "review"]
            ])
        ))

        XCTAssertNil(contextBuilderFollowUpChatID(for: reviewWithPlanOnly))
        XCTAssertNil(contextBuilderFollowUpChatID(for: unknownWithPlan))
        XCTAssertNil(contextBuilderFollowUpChatID(for: planWithReviewOnly))
        XCTAssertNil(contextBuilderFollowUpChatID(for: missingResponseType))
    }

    private func contextBuilderDTO(responseType: String) throws -> ToolResultDTOs.ContextBuilderDTO {
        let raw = jsonString([
            "status": "success",
            "response_type": responseType,
            "plan": ["chat_id": "plan-chat", "mode": "plan"],
            "review": ["chat_id": "review-chat", "mode": "review"]
        ])
        return try XCTUnwrap(ToolJSON.decode(ToolResultDTOs.ContextBuilderDTO.self, from: raw))
    }

    private func toolResultItem(toolName: String, payload: [String: Any]) -> AgentChatItem {
        let raw = jsonString(payload)
        return AgentChatItem(
            kind: .toolResult,
            text: raw,
            toolName: toolName,
            toolResultJSON: raw
        )
    }

    private func jsonString(
        _ object: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String {
        XCTAssertTrue(JSONSerialization.isValidJSONObject(object), file: file, line: line)
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }
}
