@testable import RepoPromptApp
import RepoPromptDomainRuntime
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
        XCTAssertEqual(userInfo["presentation"] as? String, "generated_answer_read_only")
        XCTAssertEqual(
            AgentOraclePopoverRoute(notificationUserInfo: userInfo)?.presentation,
            .generatedAnswerReadOnly
        )
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
            "chatID",
            "presentation"
        ])
        XCTAssertEqual(userInfo["windowID"] as? Int, 8)
        XCTAssertEqual(userInfo["workspaceID"] as? UUID, route.workspaceID)
        XCTAssertEqual(userInfo["tabID"] as? UUID, route.tabID)
        XCTAssertEqual(userInfo["chatID"] as? String, "generated-answer-chat")
        XCTAssertEqual(userInfo["presentation"] as? String, "generated_answer_read_only")
        let decodedRoute = try XCTUnwrap(AgentOraclePopoverRoute(notificationUserInfo: userInfo))
        XCTAssertEqual(decodedRoute.chatID, "generated-answer-chat")
        XCTAssertEqual(decodedRoute.presentation, .generatedAnswerReadOnly)

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
        XCTAssertEqual(route.presentation, .standard)

        let userInfo = route.notificationUserInfo
        XCTAssertEqual(userInfo["windowID"] as? Int, 42)
        XCTAssertEqual(userInfo["workspaceID"] as? UUID, workspaceID)
        XCTAssertEqual(userInfo["tabID"] as? UUID, overrideTabID)
        XCTAssertEqual(userInfo["chatID"] as? String, "exact-short-id")
        XCTAssertNil(userInfo["presentation"])
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
        XCTAssertEqual(stringCompatibleRoute.presentation, .standard)

        let readOnlyRoute = try XCTUnwrap(AgentOraclePopoverRoute(
            openContext: openContext,
            chatID: "exact-short-id",
            tabID: overrideTabID,
            presentation: .generatedAnswerReadOnly
        ))
        XCTAssertNotEqual(readOnlyRoute, route)
        XCTAssertEqual(readOnlyRoute.notificationUserInfo["presentation"] as? String, "generated_answer_read_only")
        XCTAssertEqual(AgentOraclePopoverRoute(notificationUserInfo: readOnlyRoute.notificationUserInfo), readOnlyRoute)

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
        malformed = valid
        malformed["presentation"] = "unknown"
        XCTAssertNil(AgentOraclePopoverRoute(notificationUserInfo: malformed))
        malformed = valid
        malformed["presentation"] = 42
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

final class OracleLaneCoverageTests: XCTestCase {
    @MainActor
    func testCancelledPartialGroupRetainsCanonicalOutcomeAndLaneCoverage() throws {
        var payload = try canonicalGroupPayload(completedCount: 1)
        var lanes = try XCTUnwrap(payload["oracle_results"] as? [[String: Any]])
        lanes[1]["status"] = "cancelled"
        lanes[1]["error"] = ["code": "cancelled", "message": "Cancelled"]
        payload["oracle_results"] = lanes
        var row = AgentChatItem(
            kind: .toolResult, text: "", toolName: "ask_oracle",
            toolResultJSON: jsonString(payload), toolIsError: true
        )
        for _ in 0 ... 2 {
            XCTAssertEqual(AgentTranscriptToolNormalizer.status(for: row), .warning)
            let dto = try XCTUnwrap(ToolJSON.decode(ToolResultDTOs.ChatSendDTO.self, from: row.toolResultJSON))
            XCTAssertEqual(dto.status, "partial_failure")
            XCTAssertEqual(dto.oracleGroupID, payload["oracle_group_id"] as? String)
            let coverage = try XCTUnwrap(OracleLaneCoverage(lanes: dto.oracleResults, oracleCount: dto.oracleCount))
            XCTAssertEqual(coverage.completedCount, 1)
            XCTAssertEqual(coverage.totalCount, 2)
            XCTAssertEqual(coverage.incompleteLanes.map(\.reason), ["cancelled"])
            XCTAssertEqual(ChatSendResultCard(item: row, oracleOpenContext: nil).status, .warning)
            row.toolResultJSON = try XCTUnwrap(AgentToolResultPersistencePolicy.persistedToolResultSummary(for: row)).resultJSON
        }
    }

    @MainActor
    func testOversizedGroupSummariesKeepIncompleteCardOutcomeWithoutInventingCoverage() async throws {
        let composition = WindowStateCompositionFactory.make(
            windowID: -9820, deferredInitialAgentSystemWorkspaceRefresh: true, sharedMCPService: MCPService()
        )
        await composition.workspaceManager.awaitInitialized()
        defer {
            composition.contextBuilderAgentViewModel.prepareForWindowClose()
            composition.workspaceManager.prepareForWindowClose()
        }
        addTeardownBlock { await composition.workspaceManager.awaitOwnSavesForWindowClose() }
        let context = ContextBuilderCardContext(
            tabID: nil, contextBuilderAgentVM: composition.contextBuilderAgentViewModel,
            activeContextBuilderCallItemID: nil, activeContextBuilderResultItemID: nil, oracleOpenContext: nil
        )
        for completedCount in [1, 0] {
            for tool in ["ask_oracle", "oracle_send", "plan", "review"] {
                let reply = try canonicalGroupPayload(completedCount: completedCount, laneCount: 5, oversized: true)
                let isBuilder = tool == "plan" || tool == "review"
                let raw = isBuilder ? ["status": "success", "response_type": tool, tool: reply] : reply
                var item = AgentChatItem(
                    kind: .toolResult,
                    text: "",
                    toolName: isBuilder ? "context_builder" : tool,
                    toolResultJSON: jsonString(raw),
                    toolIsError: false
                )
                let expected: ToolCardStatus = completedCount == 0 ? .failure : .warning
                for pass in 1 ... 2 {
                    let summary = try XCTUnwrap(AgentToolResultPersistencePolicy.persistedToolResultSummary(for: item))
                    XCTAssertLessThanOrEqual(summary.resultJSON.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)
                    XCTAssertFalse(summary.resultJSON.contains("oracle_results"), "fixture must exercise budget fallback")
                    XCTAssertFalse(summary.resultJSON.contains("RESPONSE_BODY"))
                    item.toolResultJSON = summary.resultJSON
                    item.text = summary.resultJSON
                    if isBuilder {
                        let card = ContextBuilderResultCard(item: item, context: context)
                        XCTAssertEqual(card.status, expected, "\(tool) pass \(pass)")
                        XCTAssertFalse(["success", "completed"].contains(card.summary), card.summary)
                        let dto = try XCTUnwrap(ToolJSON.decode(ToolResultDTOs.ContextBuilderDTO.self, from: item.toolResultJSON))
                        XCTAssertNil(contextBuilderOracleLaneCoverage(for: dto))
                        XCTAssertEqual(contextBuilderFollowUpChatID(for: dto), "fixture-chat-0")
                    } else {
                        XCTAssertEqual(ChatSendResultCard(item: item, oracleOpenContext: nil).status, expected, "\(tool) pass \(pass)")
                        let dto = try XCTUnwrap(ToolJSON.decode(ToolResultDTOs.ChatSendDTO.self, from: item.toolResultJSON))
                        XCTAssertNil(OracleLaneCoverage(lanes: dto.oracleResults, oracleCount: dto.oracleCount))
                        XCTAssertEqual(dto.chatID, "fixture-chat-0")
                    }
                }
            }
        }
    }

    func testTimeoutReasonBeyondDigestCutoffSurvivesRepeatedSummary() throws {
        for timedOut in [false, true] {
            let reply = try canonicalGroupPayload(completedCount: 1, errorMessage: String(repeating: "x", count: 96) + (timedOut ? " request timed out" : " provider refused"))
            var item = AgentChatItem(kind: .toolResult, text: "", toolName: "ask_oracle", toolResultJSON: jsonString(reply), toolIsError: false)
            for pass in 0 ... 2 {
                let dto = try XCTUnwrap(ToolJSON.decode(ToolResultDTOs.ChatSendDTO.self, from: item.toolResultJSON))
                let coverage = try XCTUnwrap(OracleLaneCoverage(lanes: dto.oracleResults, oracleCount: dto.oracleCount))
                XCTAssertEqual(coverage.incompleteLanes.map(\.reason), [timedOut ? "timed out" : "failed"], "pass \(pass)")
                if pass > 0 {
                    XCTAssertEqual(dto.oracleResults?.last?.error?.code, "provider_error")
                    XCTAssertLessThanOrEqual(dto.oracleResults?.last?.error?.message.count ?? Int.max, 96)
                }
                if pass < 2 {
                    item.toolResultJSON = try XCTUnwrap(AgentToolResultPersistencePolicy.persistedToolResultSummary(for: item)).resultJSON
                }
            }
        }
    }

    @MainActor
    func testFreshDiskStoreAndProductionPresentationPreserveOracleOutcomeAndHandle() async throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent("OracleDiskFixture-\(UUID().uuidString)")
        let workspace = WorkspaceModel(name: "Oracle disk fixture", repoPaths: [], customStoragePath: storage)
        defer { try? FileManager.default.removeItem(at: storage) }
        let composition = WindowStateCompositionFactory.make(
            windowID: -9821, deferredInitialAgentSystemWorkspaceRefresh: true, sharedMCPService: MCPService()
        )
        await composition.workspaceManager.awaitInitialized()
        defer {
            composition.contextBuilderAgentViewModel.prepareForWindowClose()
            composition.workspaceManager.prepareForWindowClose()
        }
        addTeardownBlock { await composition.workspaceManager.awaitOwnSavesForWindowClose() }
        let tabID = UUID()
        let openContext = AgentOracleOpenContext(windowID: 42, workspaceID: workspace.id, tabID: tabID, chatID: "ambient-wrong-chat")
        let context = ContextBuilderCardContext(
            tabID: nil, contextBuilderAgentVM: composition.contextBuilderAgentViewModel,
            activeContextBuilderCallItemID: nil, activeContextBuilderResultItemID: nil, oracleOpenContext: openContext
        )
        let cases: [(completed: Int, oversized: Bool, toolError: Bool)] = [
            (2, false, false), (1, false, false), (0, false, false), (1, false, true),
            (1, true, false), (0, true, false)
        ]
        for fixture in cases {
            for tool in ["ask_oracle", "oracle_send", "plan", "review"] {
                let reply = try canonicalGroupPayload(
                    completedCount: fixture.completed, laneCount: fixture.oversized ? 5 : 2, oversized: fixture.oversized,
                    errorMessage: String(repeating: "x", count: 96) + " request timed out"
                )
                let isBuilder = tool == "plan" || tool == "review"
                let raw = isBuilder ? ["status": "success", "response_type": tool, tool: reply] : reply
                let row = AgentChatItem(
                    kind: .toolResult,
                    text: "",
                    toolName: isBuilder ? "context_builder" : tool,
                    toolInvocationID: UUID(),
                    toolResultJSON: jsonString(raw),
                    toolIsError: fixture.toolError
                )
                let unfinished = AgentChatItem.toolCall(name: "file_search", invocationID: UUID(), argsJSON: #"{"pattern":"pending"}"#, sequenceIndex: 1)
                let activities = [row, unfinished].map { AgentTranscriptActivity(from: $0, toolExecution: AgentTranscriptToolNormalizer.toolExecution(for: $0)) }
                var saved = AgentSession(
                    workspaceID: workspace.id, composeTabID: tabID, name: "Oracle fixture",
                    transcript: AgentTranscript(turns: [AgentTranscriptTurn(
                        responseSpans: [AgentTranscriptProviderResponseSpan(lifecycle: .open, startedAt: row.timestamp, activities: activities)],
                        terminalState: .running, startedAt: row.timestamp
                    )], nextSequenceIndex: 2), lastRunState: "running"
                )
                let expected: ToolCardStatus = (fixture.toolError && isBuilder) || fixture.completed == 0 ? .failure : fixture.completed == 2 && !fixture.oversized ? .success : .warning
                for pass in 1 ... 2 {
                    // Each awaited service call settles its exact file+metadata writes;
                    // neither load nor presentation can fall back to the source rows.
                    let fileURL = try await AgentSessionDataService().saveAgentSession(saved, for: workspace)
                    let data = try Data(contentsOf: fileURL)
                    let bytes = try XCTUnwrap(String(data: data, encoding: .utf8))
                    XCTAssertFalse(bytes.contains("RESPONSE_BODY"))
                    let onDisk = try JSONDecoder().decode(AgentSession.self, from: data)
                    let storedActivity = try XCTUnwrap(onDisk.transcript?.turns.flatMap(\.allActivities).first { $0.id == row.id })
                    let storedJSON = try XCTUnwrap(storedActivity.toolExecution?.resultJSON)
                    XCTAssertLessThanOrEqual(storedJSON.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)
                    saved = try await AgentSessionDataService().loadAgentSession(from: fileURL)
                    let transcript = try XCTUnwrap(saved.transcript)
                    let presentation = AgentSessionRestoreSupport.buildTranscriptPresentation(
                        from: transcript, sourceItems: saved.items.map { $0.toItem() }, selectedAgent: .devin,
                        previousPerformanceSnapshot: .init(), projectionProtection: .none,
                        isCompressedHistoryRevealed: true, isColdLoad: true
                    )
                    let restored = try XCTUnwrap((presentation.fullProjection.workingRows + presentation.fullProjection.archivedRows).first { $0.id == row.id })
                    XCTAssertEqual(restored.toolInvocationID, row.toolInvocationID)
                    XCTAssertEqual(transcript.turns.first?.terminalState, .cancelled)
                    XCTAssertEqual(transcript.turns.flatMap(\.allActivities).first { $0.id == unfinished.id }?.toolExecution?.status, .cancelled)
                    let dto: ToolResultDTOs.ChatSendDTO?
                    if isBuilder {
                        let builderDTO = try XCTUnwrap(ToolJSON.decode(ToolResultDTOs.ContextBuilderDTO.self, from: restored.toolResultJSON))
                        dto = tool == "plan" ? builderDTO.plan : builderDTO.review
                        XCTAssertEqual(contextBuilderFollowUpChatID(for: builderDTO), "fixture-chat-0")
                        let card = ContextBuilderResultCard(item: restored, context: context)
                        XCTAssertEqual(card.status, expected, "\(tool) \(fixture) pass \(pass)")
                        if fixture.oversized {
                            XCTAssertFalse(["success", "completed"].contains(card.summary), card.summary)
                        } else {
                            XCTAssertEqual(
                                card.summary,
                                ContextBuilderResultCard(item: row, context: context).summary,
                                "fitting digest must preserve the live outcome wording"
                            )
                        }
                    } else {
                        dto = ToolJSON.decode(ToolResultDTOs.ChatSendDTO.self, from: restored.toolResultJSON)
                        XCTAssertEqual(ChatSendResultCard(item: restored, oracleOpenContext: openContext).status, expected, "\(tool) \(fixture) pass \(pass)")
                        XCTAssertEqual(dto?.chatID, "fixture-chat-0")
                        // Existing routing rejects nested chat IDs, including lane IDs.
                        // Do not turn this outcome regression into a routing-policy change.
                        let route = oracleToolResultPopoverUserInfo(item: restored, openContext: openContext)
                        if fixture.oversized {
                            XCTAssertEqual(route?["chatID"] as? String, "fixture-chat-0")
                        } else {
                            XCTAssertNil(route)
                        }
                    }
                    if !isBuilder, fixture.completed == 1 {
                        XCTAssertEqual(dto?.status, "partial_failure", "canonical group outcome must survive persistence")
                    }
                    let coverage = OracleLaneCoverage(lanes: dto?.oracleResults, oracleCount: dto?.oracleCount)
                    if fixture.oversized {
                        XCTAssertNil(coverage)
                    } else {
                        XCTAssertEqual(coverage?.completedCount, fixture.completed)
                        XCTAssertEqual(coverage?.totalCount, 2)
                        XCTAssertEqual(coverage?.incompleteLanes.map(\.model), (fixture.completed ..< 2).map { "model-\($0)" })
                        XCTAssertEqual(coverage?.incompleteLanes.map(\.reason), Array(repeating: "timed out", count: 2 - fixture.completed))
                    }
                }
            }
        }
    }

    private func canonicalGroupPayload(
        completedCount: Int, laneCount: Int = 2, oversized: Bool = false, errorMessage: String = "Request timed out"
    ) throws -> [String: Any] {
        let lanes = try (0 ..< laneCount).map { index in
            let model = oversized ? "model-\(index)-" + String(repeating: "m", count: 48) : "model-\(index)"
            return try OracleLaneResult(
                laneIndex: index, chatID: "fixture-chat-\(index)", providerID: "custom", modelID: model,
                status: index < completedCount ? .completed : .failed,
                executionProfile: OracleExecutionProfile(providerID: "custom", modelID: model),
                response: index < completedCount ? "RESPONSE_BODY-\(index)" : nil,
                error: index < completedCount ? nil : OracleLaneError(
                    code: "provider_error", message: oversized ? String(repeating: "e", count: 96) : errorMessage,
                    partialResponse: "PARTIAL_RESPONSE_BODY-\(index)"
                )
            )
        }
        let group = try OracleGroupResult(
            groupID: OracleGroupID(rawValue: UUID()),
            status: completedCount == laneCount ? .completed : completedCount == 0 ? .failed : .partialFailure,
            oracleResults: lanes
        )
        var reply = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(OracleGroupMCPCodec.groupFields(group))) as? [String: Any])
        reply["chat_id"] = group.primary.chatID
        reply["mode"] = "review"
        reply["response"] = group.primary.response
        return reply
    }

    func testCoverageIsSilentForSingleLaneResults() {
        XCTAssertNil(OracleLaneCoverage(lanes: nil, oracleCount: nil))
        XCTAssertNil(OracleLaneCoverage(lanes: [lane(0, "gpt-6.1-sol", "completed")], oracleCount: 1))
    }

    func testShortModelNameDropsProviderPrefixes() {
        XCTAssertEqual(OracleLaneCoverage.shortModelName("anthropic/claude-opus-5"), "claude-opus-5")
        XCTAssertEqual(OracleLaneCoverage.shortModelName("claude_code__sonnet:medium"), "sonnet:medium")
        XCTAssertEqual(OracleLaneCoverage.shortModelName(" "), "model")
    }

    func testPartialGroupReportsCoverageAndWarns() throws {
        let coverage = try XCTUnwrap(OracleLaneCoverage(lanes: [
            lane(1, "anthropic/claude-opus-5", "failed", errorCode: "provider_error", errorMessage: "Request timed out after 600s"),
            lane(0, "astra-2", "completed")
        ], oracleCount: 2))
        XCTAssertEqual(coverage.completedCount, 1)
        XCTAssertEqual(coverage.totalCount, 2)
        XCTAssertEqual(coverage.summaryText, "1/2 lanes · claude-opus-5 timed out")
        XCTAssertEqual(coverage.cardStatus, .warning)
        XCTAssertFalse(coverage.summaryText.lowercased().contains("reconcil"))
    }

    @MainActor
    func testFailedPrimaryRemainsFailedWithCompletedAdditionalLaneCoverage() throws {
        let group = try OracleGroupResult(
            groupID: OracleGroupID(rawValue: UUID()), status: .failed,
            oracleResults: [
                OracleLaneResult(
                    laneIndex: 0, chatID: "failed-primary", providerID: "fixture", modelID: "primary",
                    status: .failed, error: OracleLaneError(code: "provider_error", message: "Primary failed")
                ),
                OracleLaneResult(
                    laneIndex: 1, chatID: "completed-additional", providerID: "fixture", modelID: "additional",
                    status: .completed, response: "Additional answer"
                )
            ]
        )
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(OracleGroupMCPCodec.groupFields(group))) as? [String: Any])
        for tool in ["ask_oracle", "oracle_send"] {
            var row = AgentChatItem(kind: .toolResult, text: "", toolName: tool, toolResultJSON: jsonString(payload), toolIsError: false)
            for pass in 0 ... 2 {
                XCTAssertEqual(ChatSendResultCard(item: row, oracleOpenContext: nil).status, .failure, "\(tool), pass \(pass)")
                let dto = try XCTUnwrap(ToolJSON.decode(ToolResultDTOs.ChatSendDTO.self, from: row.toolResultJSON))
                XCTAssertEqual(dto.status, "failed")
                let coverage = try XCTUnwrap(OracleLaneCoverage(lanes: dto.oracleResults, oracleCount: dto.oracleCount))
                XCTAssertEqual(coverage.summaryText, "1/2 lanes · primary failed")
                row.toolResultJSON = try XCTUnwrap(AgentToolResultPersistencePolicy.persistedToolResultSummary(for: row)).resultJSON
            }
        }
    }

    func testCompleteAndFullyFailedGroups() throws {
        let complete = try XCTUnwrap(OracleLaneCoverage(lanes: [
            lane(0, "a", "completed"), lane(1, "b", "completed")
        ], oracleCount: 2))
        XCTAssertEqual(complete.summaryText, "2/2 lanes")
        XCTAssertNil(complete.cardStatus)

        let failed = try XCTUnwrap(OracleLaneCoverage(lanes: [
            lane(0, "a", "cancelled", errorCode: "cancelled", errorMessage: "Oracle lane was cancelled."),
            lane(1, "b", "failed", errorCode: "empty_response", errorMessage: "Oracle lane returned an empty response."),
            lane(2, "c", "failed", errorCode: "provider_error", errorMessage: "boom")
        ], oracleCount: 3))
        XCTAssertEqual(failed.summaryText, "0/3 lanes · a cancelled +2")
        XCTAssertEqual(failed.cardStatus, .failure)
        XCTAssertEqual(failed.incompleteLanes.map(\.reason), ["cancelled", "empty response", "failed"])
    }

    func testCompletedContextBuilderOutcomeDoesNotOverstateLaneSuccess() throws {
        let complete = try XCTUnwrap(OracleLaneCoverage(lanes: [lane(0, "a", "completed"), lane(1, "b", "completed")], oracleCount: 2))
        let partial = try XCTUnwrap(OracleLaneCoverage(lanes: [lane(0, "a", "completed"), lane(1, "b", "failed")], oracleCount: 2))
        let failed = try XCTUnwrap(OracleLaneCoverage(lanes: [lane(0, "a", "failed"), lane(1, "b", "cancelled")], oracleCount: 2))
        for label in ["success", "completed"] {
            XCTAssertEqual(contextBuilderCompletedOutcomeLabel(label, coverage: complete, toolIsError: false), label)
            XCTAssertEqual(contextBuilderCompletedOutcomeLabel(label, coverage: partial, toolIsError: false), "partial success")
            XCTAssertEqual(contextBuilderCompletedOutcomeLabel(label, coverage: failed, toolIsError: false), "Oracle incomplete")
            XCTAssertEqual(contextBuilderCompletedOutcomeLabel(label, coverage: partial, toolIsError: true), "error")
        }
        for label in ["error", "failed", "cancelled", "partial"] {
            XCTAssertEqual(contextBuilderCompletedOutcomeLabel(label, coverage: partial, toolIsError: false), label)
        }
    }

    func testPersistedContextBuilderReviewKeepsLaneDigestWithoutResponses() throws {
        let raw: [String: Any] = [
            "context_id": "CA9D86FB-FDA0-482A-8F46-6910C089E853",
            "response_type": "review",
            "status": "success",
            "review": [
                "chat_id": "course-review-34AE57",
                "mode": "review",
                "response": String(repeating: "finding ", count: 2000),
                "oracle_group_id": "6F1E0C55-6C1F-4C1B-9B7E-1C2D3E4F5A6B",
                "status": "partial_failure",
                "oracle_count": 2,
                "oracle_results": [
                    rawLane(0, "astra-2", "completed", response: "long answer"),
                    rawLane(
                        1,
                        "claude_code__opus:high",
                        "failed",
                        profileModel: "claude-opus-5",
                        errorCode: "provider_error",
                        errorMessage: "Request timed out"
                    )
                ]
            ]
        ]
        let summary = try XCTUnwrap(AgentToolResultPersistencePolicy.persistedToolResultSummary(
            for: AgentChatItem(kind: .toolResult, text: "", toolName: "context_builder", toolResultJSON: jsonString(raw), toolIsError: false)
        ))
        XCTAssertLessThanOrEqual(summary.resultJSON.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)
        XCTAssertFalse(summary.resultJSON.contains("finding finding"), summary.resultJSON)
        XCTAssertFalse(summary.resultJSON.contains("long answer"), summary.resultJSON)

        let dto = try XCTUnwrap(ToolJSON.decode(ToolResultDTOs.ContextBuilderDTO.self, from: summary.resultJSON))
        XCTAssertEqual(dto.review?.chatID, "course-review-34AE57")
        let coverage = try XCTUnwrap(contextBuilderOracleLaneCoverage(for: dto))
        XCTAssertEqual(coverage.summaryText, "1/2 lanes · claude-opus-5 timed out")
        XCTAssertEqual(contextBuilderOracleLaneSummaries(for: dto).map(\.status), ["done", "failed"])

        let item = AgentChatItem(kind: .toolResult, text: jsonString(raw), toolName: "context_builder", toolResultJSON: jsonString(raw), toolIsError: false)
        let execution = try XCTUnwrap(AgentTranscriptToolNormalizer.toolExecution(for: item))
        let activity = AgentTranscriptActivity(from: item, toolExecution: execution)
        var transcript = AgentTranscript(turns: [AgentTranscriptTurn(
            responseSpans: [AgentTranscriptProviderResponseSpan(lifecycle: .completed, startedAt: item.timestamp, completedAt: item.timestamp, activities: [activity])],
            startedAt: item.timestamp,
            completedAt: item.timestamp
        )], nextSequenceIndex: 1)
        for pass in 1 ... 2 {
            let persisted = AgentTranscriptPolicyPipeline.persistedTranscript(from: transcript).transcript
            let encoded = try JSONEncoder().encode(persisted)
            let decoded = try JSONDecoder().decode(AgentTranscript.self, from: encoded)
            let restored = AgentTranscriptPolicyPipeline.runtimeTranscript(decoded)
            let row = try XCTUnwrap((restored.projection.workingRows + restored.projection.archivedRows).first { $0.id == item.id })
            let restoredDTO = try XCTUnwrap(ToolJSON.decode(ToolResultDTOs.ContextBuilderDTO.self, from: row.toolResultJSON))
            XCTAssertEqual(contextBuilderOracleLaneCoverage(for: restoredDTO)?.summaryText, coverage.summaryText, "round trip \(pass)")
            XCTAssertFalse(row.toolResultJSON?.contains("finding finding") == true)
            transcript = restored.transcript
        }
    }

    func testPersistedAskOracleKeepsLaneDigest() throws {
        let raw: [String: Any] = [
            "chat_id": "review-chat",
            "mode": "review",
            "response": "primary answer",
            "status": "partial_failure",
            "oracle_count": 2,
            "oracle_results": [
                rawLane(0, "astra-2", "completed", response: "primary answer"),
                rawLane(1, "claude-opus-5", "cancelled", errorCode: "cancelled", errorMessage: "Oracle lane was cancelled.")
            ]
        ]
        let summary = try XCTUnwrap(AgentToolResultPersistencePolicy.persistedToolResultSummary(
            for: AgentChatItem(kind: .toolResult, text: "", toolName: "ask_oracle", toolResultJSON: jsonString(raw), toolIsError: false)
        ))
        XCTAssertFalse(summary.resultJSON.contains("primary answer"), summary.resultJSON)
        let dto = try XCTUnwrap(ToolJSON.decode(ToolResultDTOs.ChatSendDTO.self, from: summary.resultJSON))
        XCTAssertEqual(dto.chatID, "review-chat")
        XCTAssertEqual(OracleLaneCoverage(lanes: dto.oracleResults, oracleCount: dto.oracleCount)?.summaryText, "1/2 lanes · claude-opus-5 cancelled")
    }

    func testSingleLanePersistedSummaryIsUnchanged() throws {
        let summary = try XCTUnwrap(AgentToolResultPersistencePolicy.persistedToolResultSummary(
            for: AgentChatItem(
                kind: .toolResult,
                text: "",
                toolName: "ask_oracle",
                toolResultJSON: jsonString(["chat_id": "c", "mode": "chat", "response": "x"]),
                toolIsError: false
            )
        ))
        XCTAssertFalse(summary.resultJSON.contains("oracle_results"), summary.resultJSON)
    }

    func testInvalidGroupMetadataCannotClaimCompleteCoverageOrPersistInventedCount() throws {
        let valid = [rawLane(0, "a", "completed"), rawLane(1, "b", "completed")]
        var wrongRole = valid
        wrongRole[1]["role"] = "primary"
        var negativeIndex = valid
        negativeIndex[0]["lane_index"] = -1
        let cases: [(String, Int?, [[String: Any]])] = [
            ("missing count", nil, valid), ("declared larger", 3, valid), ("declared smaller", 1, valid),
            ("duplicate index", 2, [valid[0], valid[0]]),
            ("gap", 2, [valid[0], rawLane(2, "b", "completed")]),
            ("negative index", 2, negativeIndex), ("wrong role", 2, wrongRole)
        ]
        for (label, count, lanes) in cases {
            var reply: [String: Any] = ["chat_id": "review-chat", "oracle_results": lanes]
            if let count { reply["oracle_count"] = count }
            let dto = try XCTUnwrap(ToolJSON.decode(ToolResultDTOs.ContextBuilderDTO.self, from: jsonString([
                "response_type": "review", "review": reply
            ])))
            XCTAssertTrue(contextBuilderOracleLaneSummaries(for: dto).isEmpty, label)
            XCTAssertNil(contextBuilderOracleLaneCoverage(for: dto), label)
            XCTAssertNil(AgentToolResultPersistencePolicy.oracleGroupDigest(from: reply), label)
            let summary = try XCTUnwrap(AgentToolResultPersistencePolicy.persistedToolResultSummary(
                for: AgentChatItem(kind: .toolResult, text: "", toolName: "context_builder", toolResultJSON: jsonString([
                    "response_type": "review", "review": reply
                ]), toolIsError: false)
            ))
            let restored = try XCTUnwrap(ToolJSON.decode(ToolResultDTOs.ContextBuilderDTO.self, from: summary.resultJSON))
            XCTAssertEqual(restored.review?.chatID, "review-chat", label)
            XCTAssertNil(restored.review?.oracleCount, label)
            XCTAssertNil(contextBuilderOracleLaneCoverage(for: restored), label)
        }
    }

    @MainActor
    func testInvalidGroupMetadataPreservesExplicitIncompleteCardStatus() throws {
        for (groupStatus, expected) in [("partial_failure", ToolCardStatus.warning), ("failed", .failure)] {
            let raw: [String: Any] = [
                "chat_id": "review-chat", "response": "primary answer", "status": groupStatus,
                "oracle_count": 3,
                "oracle_results": [rawLane(0, "a", "completed"), rawLane(1, "b", "failed")]
            ]
            let item = AgentChatItem(kind: .toolResult, text: "", toolName: "ask_oracle", toolResultJSON: jsonString(raw), toolIsError: false)
            let dto = try XCTUnwrap(ToolJSON.decode(ToolResultDTOs.ChatSendDTO.self, from: item.toolResultJSON))
            XCTAssertNil(OracleLaneCoverage(lanes: dto.oracleResults, oracleCount: dto.oracleCount))
            XCTAssertEqual(ChatSendResultCard(item: item, oracleOpenContext: nil).status, expected)
        }
    }

    func testExplicitCancelledOracleToolResultKeepsCancellationDuringPersistence() throws {
        for tool in ["ask_oracle", "oracle_send", "context_builder"] {
            let item = AgentChatItem(
                kind: .toolResult,
                text: "",
                toolName: tool,
                toolResultJSON: #"{"status":"cancelled"}"#,
                toolIsError: true
            )
            XCTAssertEqual(AgentTranscriptToolNormalizer.status(for: item), .cancelled)
            XCTAssertEqual(try XCTUnwrap(AgentToolResultPersistencePolicy.persistedToolResultSummary(for: item)).transcriptStatus, .cancelled)
        }
    }

    // MARK: - Helpers

    private func lane(
        _ index: Int,
        _ model: String,
        _ status: String,
        errorCode: String? = nil,
        errorMessage: String? = nil
    ) -> ToolResultDTOs.ChatSendDTO.OracleLaneDTO {
        let json = jsonString(rawLane(index, model, status, errorCode: errorCode, errorMessage: errorMessage))
        return ToolJSON.decode(ToolResultDTOs.ChatSendDTO.OracleLaneDTO.self, from: json)!
    }

    private func rawLane(
        _ index: Int,
        _ model: String,
        _ status: String,
        response: String? = nil,
        profileModel: String? = nil,
        errorCode: String? = nil,
        errorMessage: String? = nil
    ) -> [String: Any] {
        var lane: [String: Any] = [
            "lane_index": index,
            "role": index == 0 ? "primary" : "additional",
            "chat_id": "chat-\(index)",
            "model_id": model,
            "status": status
        ]
        if let response { lane["response"] = response }
        if let profileModel {
            lane["execution_profile"] = ["provider_id": "provider", "model_id": profileModel, "effective_reasoning_effort": "high"]
        }
        if let errorCode {
            lane["error"] = ["code": errorCode, "message": errorMessage ?? errorCode]
        }
        return lane
    }

    private func jsonString(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
