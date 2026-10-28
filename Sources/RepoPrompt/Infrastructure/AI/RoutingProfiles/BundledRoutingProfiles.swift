import Foundation

/// Immutable routing annotations compiled into the app target. This avoids process-specific
/// resource bundle lookup and gives tests and the packaged app the same exact bytes.
enum BundledRoutingProfiles {
    static let data = Data((#"""
    {
      "schemaVersion": 1,
      "profileVersion": "rpce.bundled-routing-profiles.2026-10-26.1",
      "evidenceVersion": "rpce.model-routing-evidence.2026-10-26.1",
      "rubricVersion": "rpce.capability-first-frontier.v3-evidence-2026-10-26.1",
      "issuedAt": "2026-09-23T00:00:00Z",
      "expiresAt": "2027-09-23T00:00:00Z",
      "families": [
        {
          "providerID": "codexExec",
          "id": "luna",
          "utilityTier": "gpt-6-luna",
          "summary": "Provider-scoped luna family; exact capability and cost depend on the advertised model.",
          "rubric": "Luna is a light, high-volume tier meant for exploration and simple lookups. Not suitable for implementation, review, debugging, or multi-step agentic work. A short prompt does not make a task simple.",
          "aliases": [],
          "matchers": [
            {
              "kind": "versionedPrefix",
              "prefix": "gpt-6-luna-"
            }
          ]
        },
        {
          "providerID": "codexExec",
          "id": "terra",
          "utilityTier": "gpt-5.6-terra",
          "summary": "Provider-scoped terra family; exact capability and cost depend on the advertised model.",
          "rubric": "Terra is a previous-generation balanced tier, weaker than current flagships. Choose it only for clearly bounded, routine work; it is not cheaper than Sol.",
          "aliases": [],
          "matchers": []
        },
        {
          "providerID": "codexExec",
          "id": "sol",
          "utilityTier": "gpt-6-sol",
          "summary": "Provider-scoped sol family; exact capability and cost depend on the advertised model.",
          "rubric": "Sol is OpenAI's current flagship for complex coding and agentic work. Strong default for substantive primary work; its base capability avoids missed findings and retries.",
          "aliases": [],
          "matchers": [
            {
              "kind": "versionedPrefix",
              "prefix": "gpt-6-sol-"
            }
          ]
        },
        {
          "providerID": "codexExec",
          "id": "astra",
          "utilityTier": "gpt-6-astra",
          "summary": "Provider-scoped astra family; exact capability and cost depend on the advertised model.",
          "rubric": "Astra is OpenAI's most capable premium tier. Choose it for the hardest, highest-risk, or longest-horizon work where its extra capability justifies premium price.",
          "aliases": [],
          "matchers": []
        },
        {
          "providerID": "claudeCode",
          "id": "haiku",
          "utilityTier": "claude-haiku",
          "summary": "Provider-scoped haiku family; exact capability and cost depend on the advertised model.",
          "rubric": "Haiku is a light, fast tier meant for exploration and simple lookups. Not suitable for implementation, review, debugging, or multi-step agentic work. A short prompt does not make a task simple.",
          "aliases": [],
          "matchers": []
        },
        {
          "providerID": "claudeCode",
          "id": "sonnet",
          "utilityTier": "claude-sonnet",
          "summary": "Provider-scoped sonnet family; exact capability and cost depend on the advertised model.",
          "rubric": "Sonnet is a balanced tier below the flagships. Choose it only for clearly bounded, routine work with a clear reliability margin.",
          "aliases": [
            "sonnet-family"
          ],
          "matchers": [
            {
              "kind": "versionedPrefix",
              "prefix": "claude-sonnet-5-"
            }
          ]
        },
        {
          "providerID": "claudeCode",
          "id": "opus",
          "utilityTier": "claude-opus",
          "summary": "Provider-scoped opus family; exact capability and cost depend on the advertised model.",
          "rubric": "Opus is Anthropic's recommended flagship for long-running agentic coding and knowledge work. Strong default for substantive primary work; its base capability avoids missed findings and retries.",
          "aliases": [],
          "matchers": []
        },
        {
          "providerID": "claudeCode",
          "id": "fable",
          "utilityTier": "claude-fable",
          "summary": "Provider-scoped fable family; exact capability and cost depend on the advertised model.",
          "rubric": "Fable is Anthropic's most capable premium tier. Choose it for the hardest, highest-risk, or longest-horizon work where its extra capability justifies premium price.",
          "aliases": [],
          "matchers": []
        }
      ],
      "models": [
        {
          "providerID": "codexExec",
          "id": "gpt-6-luna",
          "aliases": [],
          "familyID": "luna",
          "utilityTier": "gpt-6-luna",
          "summary": "GPT-6 Luna is OpenAI's light, high-volume GPT-6 tier (nano class) for exploration, lookups, and simple bounded edits; it is not intended for substantive implementation, review, or multi-step agentic work. 1.05M-token context window and 128K-token maximum output.",
          "rubric": null,
          "price": {
            "text": "API list price: $0.10 input / $0.50 output per 1M tokens.",
            "checkedAt": "2026-09-23T00:00:00Z",
            "expiresAt": "2026-12-31T00:00:00Z"
          },
          "evidenceIDs": []
        },
        {
          "providerID": "codexExec",
          "id": "gpt-5.6-luna",
          "aliases": [],
          "familyID": "luna",
          "utilityTier": "gpt-5.6-luna",
          "summary": "GPT-5.6 Luna is the prior nano-tier, fastest GPT-5.6 option for cost-sensitive, high-volume work.",
          "rubric": null,
          "price": {
            "text": "API list price: $0.20 input / $1.20 output per 1M tokens.",
            "checkedAt": "2026-09-23T00:00:00Z",
            "expiresAt": "2026-12-31T00:00:00Z"
          },
          "evidenceIDs": [
            "published-1"
          ]
        },
        {
          "providerID": "codexExec",
          "id": "gpt-5.6-terra",
          "aliases": [],
          "familyID": "terra",
          "utilityTier": "gpt-5.6-terra",
          "summary": "GPT-5.6 Terra is a previous-generation (GPT-5.6) balanced tier for routine agentic work. Current GPT-6.1 Sol is more capable at a lower list price. Its benchmark figures below are not directly comparable to unlisted GPT-6 models.",
          "rubric": null,
          "price": {
            "text": "API list price: $2 input / $12 output per 1M tokens.",
            "checkedAt": "2026-09-23T00:00:00Z",
            "expiresAt": "2026-12-31T00:00:00Z"
          },
          "evidenceIDs": [
            "published-2"
          ]
        },
        {
          "providerID": "codexExec",
          "id": "gpt-6-sol",
          "aliases": [],
          "familyID": "sol",
          "utilityTier": "gpt-6-sol",
          "summary": "GPT-6 Sol is OpenAI's flagship GPT-6 tier for complex coding and agentic work, with a 1.05M-token context window and 128K-token maximum output.",
          "rubric": null,
          "price": {
            "text": "API list price: $2 input / $10 output per 1M tokens.",
            "checkedAt": "2026-09-23T00:00:00Z",
            "expiresAt": "2026-12-31T00:00:00Z"
          },
          "evidenceIDs": []
        },
        {
          "providerID": "codexExec",
          "id": "gpt-5.6-sol",
          "aliases": [],
          "familyID": "sol",
          "utilityTier": "gpt-5.6-sol",
          "summary": "GPT-5.6 Sol is the prior flagship tier for complex professional work.",
          "rubric": null,
          "price": {
            "text": "API list price: $4 input / $20 output per 1M tokens.",
            "checkedAt": "2026-09-23T00:00:00Z",
            "expiresAt": "2026-12-31T00:00:00Z"
          },
          "evidenceIDs": [
            "published-3"
          ]
        },
        {
          "providerID": "codexExec",
          "id": "gpt-5.6",
          "aliases": [],
          "familyID": "sol",
          "utilityTier": "gpt-5.6",
          "summary": "GPT-5.6 Sol is the prior flagship tier for complex professional work.",
          "rubric": null,
          "price": {
            "text": "API list price: $4 input / $20 output per 1M tokens.",
            "checkedAt": "2026-09-23T00:00:00Z",
            "expiresAt": "2026-12-31T00:00:00Z"
          },
          "evidenceIDs": [
            "published-3"
          ]
        },
        {
          "providerID": "codexExec",
          "id": "gpt-6-astra",
          "aliases": [],
          "familyID": "astra",
          "utilityTier": "gpt-6-astra",
          "summary": "GPT-6 Astra is OpenAI's most capable tier for the hardest end-to-end reasoning, coding, research, and computer-use work.",
          "rubric": null,
          "price": {
            "text": "API list price: $10 input / $50 output per 1M tokens. No directly comparable coding score is included in this snapshot.",
            "checkedAt": "2026-09-23T00:00:00Z",
            "expiresAt": "2026-12-31T00:00:00Z"
          },
          "evidenceIDs": []
        },
        {
          "providerID": "claudeCode",
          "id": "haiku",
          "aliases": [
            "claude-haiku-4-5",
            "claude-haiku-4-5-20251001"
          ],
          "familyID": "haiku",
          "utilityTier": "claude-haiku",
          "summary": "Claude Haiku 4.5 is the fast, economical Claude tier for responsive and bounded work.",
          "rubric": null,
          "price": {
            "text": "API list price: $1 input / $5 output per 1M tokens.",
            "checkedAt": "2026-09-23T00:00:00Z",
            "expiresAt": "2026-12-31T00:00:00Z"
          },
          "evidenceIDs": [
            "published-4"
          ]
        },
        {
          "providerID": "claudeCode",
          "id": "sonnet",
          "aliases": [
            "sonnet[1m]",
            "claude-sonnet-5"
          ],
          "familyID": "sonnet",
          "utilityTier": "claude-sonnet",
          "summary": "Claude Sonnet 5 is the balanced Claude tier for sustained everyday coding, tool use, and debugging.",
          "rubric": null,
          "price": {
            "text": "API list price: $2 input / $10 output per 1M tokens.",
            "checkedAt": "2026-09-23T00:00:00Z",
            "expiresAt": "2026-12-31T00:00:00Z"
          },
          "evidenceIDs": [
            "published-5"
          ]
        },
        {
          "providerID": "claudeCode",
          "id": "claude-sonnet-4-6",
          "aliases": [
            "claude-sonnet-4-5",
            "claude-sonnet-4-5-20250929"
          ],
          "familyID": "sonnet",
          "utilityTier": "claude-sonnet-4-6",
          "summary": "This is an older Claude Sonnet tier for balanced coding and analysis.",
          "rubric": null,
          "price": {
            "text": "API list price: $3 input / $15 output per 1M tokens. No current comparable coding score is included in this snapshot.",
            "checkedAt": "2026-09-23T00:00:00Z",
            "expiresAt": "2026-12-31T00:00:00Z"
          },
          "evidenceIDs": []
        },
        {
          "providerID": "claudeCode",
          "id": "opus",
          "aliases": [
            "opus[1m]",
            "claude-opus-5-5"
          ],
          "familyID": "opus",
          "utilityTier": "claude-opus",
          "summary": "Claude Opus 5.5 is Anthropic's recommended starting point for most workloads and is built for long-running agentic coding and knowledge work, with a 1M-token context window and medium default effort.",
          "rubric": null,
          "price": {
            "text": "API list price: $4 input / $20 output per 1M tokens.",
            "checkedAt": "2026-09-23T00:00:00Z",
            "expiresAt": "2026-12-31T00:00:00Z"
          },
          "evidenceIDs": []
        },
        {
          "providerID": "claudeCode",
          "id": "claude-opus-5",
          "aliases": [],
          "familyID": "opus",
          "utilityTier": "claude-opus",
          "summary": "Claude Opus 5 is an older premium tier for production-ready code, long-running agents, difficult debugging, and complex knowledge work.",
          "rubric": null,
          "price": {
            "text": "API list price: $5 input / $25 output per 1M tokens.",
            "checkedAt": "2026-09-23T00:00:00Z",
            "expiresAt": "2026-12-31T00:00:00Z"
          },
          "evidenceIDs": []
        },
        {
          "providerID": "claudeCode",
          "id": "claude-opus-4-8",
          "aliases": [
            "claude-opus-4-7",
            "claude-opus-4-6",
            "claude-opus-4-5",
            "claude-opus-4-5-20251101"
          ],
          "familyID": "opus",
          "utilityTier": "claude-opus-4-8",
          "summary": "This is an older premium Claude Opus tier for complex coding and agentic work.",
          "rubric": null,
          "price": {
            "text": "API list price: $5 input / $25 output per 1M tokens. No current comparable coding score is included in this snapshot.",
            "checkedAt": "2026-09-23T00:00:00Z",
            "expiresAt": "2026-12-31T00:00:00Z"
          },
          "evidenceIDs": []
        },
        {
          "providerID": "claudeCode",
          "id": "fable",
          "aliases": [
            "claude-fable-5-1"
          ],
          "familyID": "fable",
          "utilityTier": "claude-fable",
          "summary": "Claude Fable 5.1 is Anthropic's most capable generally available tier for ambitious, long-running, cross-codebase work.",
          "rubric": null,
          "price": {
            "text": "API list price: $10 input / $50 output per 1M tokens.",
            "checkedAt": "2026-09-23T00:00:00Z",
            "expiresAt": "2026-12-31T00:00:00Z"
          },
          "evidenceIDs": [
            "published-6"
          ]
        },
        {
          "providerID": "claudeCode",
          "id": "claude-fable-5",
          "aliases": [],
          "familyID": "fable",
          "utilityTier": "claude-fable-5",
          "summary": "Claude Fable 5 is a frontier tier for ambitious, long-running work.",
          "rubric": null,
          "price": {
            "text": "API list price: $10 input / $50 output per 1M tokens.",
            "checkedAt": "2026-09-23T00:00:00Z",
            "expiresAt": "2026-12-31T00:00:00Z"
          },
          "evidenceIDs": [
            "published-7"
          ]
        },
        {
          "providerID": "codexExec",
          "id": "gpt-6.1-sol",
          "aliases": [],
          "familyID": "sol",
          "utilityTier": "gpt-6-sol",
          "summary": "GPT-6.1 Sol (released 2026-09-29) is OpenAI's current flagship Sol tier and the Codex CLI default for complex coding and agentic work, with a 1.05M-token context window, 128K-token maximum output, and low through max reasoning effort (medium default).",
          "rubric": null,
          "price": {
            "text": "API list price: $2 input / $10 output per 1M tokens (cached input $0.10, half of GPT-6 Sol's); requests above 272K input tokens bill at $4 input / $15 output.",
            "checkedAt": "2026-09-30T00:00:00Z",
            "expiresAt": "2026-12-31T00:00:00Z"
          },
          "evidenceIDs": []
        },
        {
          "providerID": "claudeCode",
          "id": "claude-sonnet-5-5",
          "aliases": [],
          "familyID": "sonnet",
          "utilityTier": "claude-sonnet",
          "summary": "Claude Sonnet 5.5 (released 2026-09-28) is Anthropic's current balanced Claude tier for sustained everyday coding, tool use, and debugging, with a 1M-token context window, 128K-token maximum output, and adaptive thinking at low through max effort (high default).",
          "rubric": null,
          "price": {
            "text": "API list price: $2 input / $10 output per 1M tokens (cached input $0.20).",
            "checkedAt": "2026-09-30T00:00:00Z",
            "expiresAt": "2026-12-31T00:00:00Z"
          },
          "evidenceIDs": []
        }
      ],
      "evidence": [
        {
          "id": "published-1",
          "text": "OpenAI reports 74.6 on Artificial Analysis Coding Agent Index v1.1 and 84.7% on Terminal-Bench 2.1.",
          "publisher": "OpenAI",
          "sourceURL": null,
          "checkedAt": "2026-09-23T00:00:00Z",
          "expiresAt": "2026-12-31T00:00:00Z",
          "familyWide": false
        },
        {
          "id": "published-2",
          "text": "OpenAI reports 77.4 on Artificial Analysis Coding Agent Index v1.1 and 87.4% on Terminal-Bench 2.1.",
          "publisher": "OpenAI",
          "sourceURL": null,
          "checkedAt": "2026-09-23T00:00:00Z",
          "expiresAt": "2026-12-31T00:00:00Z",
          "familyWide": false
        },
        {
          "id": "published-3",
          "text": "OpenAI reports 80.0 on Artificial Analysis Coding Agent Index v1.1 and 88.8% on Terminal-Bench 2.1.",
          "publisher": "OpenAI",
          "sourceURL": null,
          "checkedAt": "2026-09-23T00:00:00Z",
          "expiresAt": "2026-12-31T00:00:00Z",
          "familyWide": false
        },
        {
          "id": "published-4",
          "text": "Anthropic reports similar coding performance to Sonnet 4 and 90% of Sonnet 4.5 on Augment's agentic coding evaluation.",
          "publisher": "Anthropic",
          "sourceURL": null,
          "checkedAt": "2026-09-23T00:00:00Z",
          "expiresAt": "2026-12-31T00:00:00Z",
          "familyWide": false
        },
        {
          "id": "published-5",
          "text": "Anthropic reports that high effort can match Opus 4.8 on some agentic search and computer-use tasks.",
          "publisher": "Anthropic",
          "sourceURL": null,
          "checkedAt": "2026-09-23T00:00:00Z",
          "expiresAt": "2026-12-31T00:00:00Z",
          "familyWide": false
        },
        {
          "id": "published-6",
          "text": "Anthropic reports 55.8% on Terminal-Bench 4.0 versus 52.3% for Opus 5 in its harness.",
          "publisher": "Anthropic",
          "sourceURL": null,
          "checkedAt": "2026-09-23T00:00:00Z",
          "expiresAt": "2026-12-31T00:00:00Z",
          "familyWide": false
        },
        {
          "id": "published-7",
          "text": "Anthropic reports 42.0% on Terminal-Bench 4.0 in its later comparison.",
          "publisher": "Anthropic",
          "sourceURL": null,
          "checkedAt": "2026-09-23T00:00:00Z",
          "expiresAt": "2026-12-31T00:00:00Z",
          "familyWide": false
        }
      ],
      "efforts": [
        {
          "id": "low",
          "aliases": [
            "none",
            "minimal"
          ],
          "description": "Effort: {effort}; lower test-time compute favors latency and cost, so use it only when the task has a clear reliability margin."
        },
        {
          "id": "medium",
          "aliases": [],
          "description": "Effort: medium; balanced test-time compute for routine execution."
        },
        {
          "id": "high",
          "aliases": [
            "xhigh",
            "x-high"
          ],
          "description": "Effort: {effort}; deeper test-time reasoning can improve difficult-task reliability but may increase tokens, latency, and total cost."
        },
        {
          "id": "max",
          "aliases": [
            "maximum",
            "ultra"
          ],
          "description": "Effort: {effort}; reserve this highest-compute setting for exceptional complexity because tokens, latency, and total cost can rise substantially."
        }
      ]
    }
    """# + "\n").utf8)
}
