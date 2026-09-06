import Foundation

/// Captured from bundled Codex 0.149.0 using an isolated synthetic HTTP fixture.
/// External IP networking was denied. No real login or provider service was used.
/// Includes initial metadata-only state and completed A/B history; only private
/// filesystem paths are substituted. Refresh fixtures after reviewed runtime upgrades.
enum CodexManagedHTTPThreadFixture {
    static func responses() throws -> [[String: Any]] {
        let data = Data(json.utf8)
        return try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
    }

    private static let json = #"""
    [
      {
        "started": {
          "thread": {
            "id": "01a078b2-05d5-7091-89e0-b0669e86484b",
            "extra": null,
            "sessionId": "01a078b2-05d5-7091-89e0-b0669e86484b",
            "forkedFromId": null,
            "parentThreadId": null,
            "preview": "",
            "ephemeral": false,
            "section": null,
            "sectionEnteredAt": null,
            "projectId": null,
            "historyMode": "legacy",
            "modelProvider": "switchboard-managed-http",
            "createdAt": 1788731327,
            "updatedAt": 1788731327,
            "recencyAt": 1788731327,
            "status": {
              "type": "idle"
            },
            "path": "/synthetic/path",
            "cwd": "/synthetic/path",
            "cliVersion": "0.149.0",
            "source": "vscode",
            "canAcceptDirectInput": true,
            "threadSource": null,
            "agentNickname": null,
            "agentRole": null,
            "gitInfo": null,
            "name": null,
            "turns": []
          },
          "model": "gpt-5.6-sol",
          "modelProvider": "switchboard-managed-http",
          "serviceTier": null,
          "cwd": "/synthetic/path",
          "runtimeWorkspaceRoots": [
            "/synthetic/path"
          ],
          "instructionSources": [],
          "approvalPolicy": "never",
          "approvalsReviewer": "user",
          "sandbox": {
            "type": "readOnly",
            "networkAccess": false
          },
          "activePermissionProfile": null,
          "reasoningEffort": null,
          "multiAgentMode": "explicitRequestOnly"
        },
        "loaded": {
          "data": [
            "01a078b2-05d5-7091-89e0-b0669e86484b"
          ],
          "nextCursor": null
        },
        "read": {
          "thread": {
            "id": "01a078b2-05d5-7091-89e0-b0669e86484b",
            "extra": null,
            "sessionId": "01a078b2-05d5-7091-89e0-b0669e86484b",
            "forkedFromId": null,
            "parentThreadId": null,
            "preview": "",
            "ephemeral": false,
            "section": null,
            "sectionEnteredAt": null,
            "projectId": null,
            "historyMode": "legacy",
            "modelProvider": "switchboard-managed-http",
            "createdAt": 1788731327,
            "updatedAt": 1788731327,
            "recencyAt": 1788731327,
            "status": {
              "type": "idle"
            },
            "path": "/synthetic/path",
            "cwd": "/synthetic/path",
            "cliVersion": "0.149.0",
            "source": "vscode",
            "canAcceptDirectInput": true,
            "threadSource": null,
            "agentNickname": null,
            "agentRole": null,
            "gitInfo": null,
            "name": null,
            "turns": []
          }
        }
      },
      {
        "read": {
          "thread": {
            "id": "01a078b3-0d92-74b3-8cf9-7a7010b10558",
            "extra": null,
            "sessionId": "01a078b3-0d92-74b3-8cf9-7a7010b10558",
            "forkedFromId": null,
            "parentThreadId": null,
            "preview": "ROUTING_SEED",
            "ephemeral": false,
            "section": null,
            "sectionEnteredAt": null,
            "projectId": null,
            "historyMode": "legacy",
            "modelProvider": "switchboard-managed-http",
            "createdAt": 1788731395,
            "updatedAt": 1788731395,
            "recencyAt": 1788731395,
            "status": {
              "type": "idle"
            },
            "path": "/synthetic/path",
            "cwd": "/synthetic/path",
            "cliVersion": "0.149.0",
            "source": "vscode",
            "canAcceptDirectInput": true,
            "threadSource": null,
            "agentNickname": null,
            "agentRole": null,
            "gitInfo": null,
            "name": null,
            "turns": [
              {
                "id": "01a078b3-0da7-72d0-9f57-c29d1f53bcfe",
                "items": [
                  {
                    "type": "userMessage",
                    "id": "item-1",
                    "clientId": null,
                    "content": [
                      {
                        "type": "text",
                        "text": "ROUTING_SEED",
                        "text_elements": []
                      }
                    ]
                  },
                  {
                    "type": "agentMessage",
                    "id": "item-2",
                    "text": "ROUTED a@example.invalid",
                    "phase": null,
                    "memoryCitation": null,
                    "delivery": null
                  }
                ],
                "itemsView": "full",
                "status": "completed",
                "error": null,
                "startedAt": 1788731395,
                "completedAt": 1788731395,
                "durationMs": 29
              }
            ]
          }
        },
        "loaded": {
          "data": [
            "01a078b3-0d92-74b3-8cf9-7a7010b10558"
          ],
          "nextCursor": null
        }
      },
      {
        "read": {
          "thread": {
            "id": "01a078b3-0d92-74b3-8cf9-7a7010b10558",
            "extra": null,
            "sessionId": "01a078b3-0d92-74b3-8cf9-7a7010b10558",
            "forkedFromId": null,
            "parentThreadId": null,
            "preview": "ROUTING_SEED",
            "ephemeral": false,
            "section": null,
            "sectionEnteredAt": null,
            "projectId": null,
            "historyMode": "legacy",
            "modelProvider": "switchboard-managed-http",
            "createdAt": 1788731395,
            "updatedAt": 1788731395,
            "recencyAt": 1788731395,
            "status": {
              "type": "idle"
            },
            "path": "/synthetic/path",
            "cwd": "/synthetic/path",
            "cliVersion": "0.149.0",
            "source": "vscode",
            "canAcceptDirectInput": true,
            "threadSource": null,
            "agentNickname": null,
            "agentRole": null,
            "gitInfo": null,
            "name": null,
            "turns": [
              {
                "id": "01a078b3-0da7-72d0-9f57-c29d1f53bcfe",
                "items": [
                  {
                    "type": "userMessage",
                    "id": "item-1",
                    "clientId": null,
                    "content": [
                      {
                        "type": "text",
                        "text": "ROUTING_SEED",
                        "text_elements": []
                      }
                    ]
                  },
                  {
                    "type": "agentMessage",
                    "id": "item-2",
                    "text": "ROUTED a@example.invalid",
                    "phase": null,
                    "memoryCitation": null,
                    "delivery": null
                  }
                ],
                "itemsView": "full",
                "status": "completed",
                "error": null,
                "startedAt": 1788731395,
                "completedAt": 1788731395,
                "durationMs": 29
              },
              {
                "id": "01a078b3-0dd6-74c2-a49b-1e98b298d077",
                "items": [
                  {
                    "type": "userMessage",
                    "id": "item-3",
                    "clientId": null,
                    "content": [
                      {
                        "type": "text",
                        "text": "Recall previous context",
                        "text_elements": []
                      }
                    ]
                  },
                  {
                    "type": "agentMessage",
                    "id": "item-4",
                    "text": "ROUTED b@example.invalid",
                    "phase": null,
                    "memoryCitation": null,
                    "delivery": null
                  }
                ],
                "itemsView": "full",
                "status": "completed",
                "error": null,
                "startedAt": 1788731395,
                "completedAt": 1788731395,
                "durationMs": 17
              }
            ]
          }
        },
        "loaded": {
          "data": [
            "01a078b3-0d92-74b3-8cf9-7a7010b10558"
          ],
          "nextCursor": null
        }
      }
    ]
    """#
}
