# Devin ACP live probe evidence (2026-09-23, Devin CLI 3000.11.1)

## Enterprise account (macOS), `devin --config <empty> acp`

session/new modes: {"currentModeId": "accept-edits", "availableModes": [{"id": "accept-edits", "name": "Code"}, {"id": "smart", "name": "Smart"}, {"id": "ask", "name": "Ask"}, {"id": "plan", "name": "Plan"}]}

- configOption `mode` category `mode` current `accept-edits` values ['accept-edits', 'smart', 'ask', 'plan']
- configOption `model` category `model` current `gpt-5-6-sol-medium` values ['claude-opus-5-5-medium', 'claude-sonnet-5-medium', 'gemini-3-8-flash-medium', 'gpt-6-astra-medium', 'gpt-6-sol-medium', 'gpt-6-luna-medium', 'swe-1-7-lightning-medium', 'swe-2-high', 'claude-opus-4-7-medium', 'claude-opus-4-8-medium', 'claude-opus-5-medium', 'gemini-3-5-flash-medium'] …
- configOption `thought_level` category `thought_level` current `medium` values ['none', 'low', 'medium', 'high', 'xhigh', 'max']
- configOption `speed` category `model_config` current `standard` values ['standard', 'fast']

Mode descriptions: [{"value": "accept-edits", "name": "Code", "description": "Write and edit code"}, {"value": "smart", "name": "Smart", "description": "Auto-approve actions the model judges safe"}, {"value": "ask", "name": "Ask", "description": "Answer questions without code changes"}, {"value": "plan", "name": "Plan", "description": "Plan changes before implementing"}]

## set_config_option sequence (thought_level independence / reset)
```json
{
 "thought_level=high": {
  "mode": "accept-edits",
  "model": "gpt-5-6-sol-medium",
  "thought_level": "high",
  "speed": "standard"
 },
 "model=claude-opus-5-5-medium": {
  "mode": "accept-edits",
  "model": "claude-opus-5-5-medium",
  "thought_level": "medium",
  "speed": "standard"
 },
 "thought_level=max": {
  "mode": "accept-edits",
  "model": "claude-opus-5-5-medium",
  "thought_level": "max",
  "speed": "standard"
 },
 "speed=fast": {
  "mode": "accept-edits",
  "model": "claude-opus-5-5-medium",
  "thought_level": "max",
  "speed": "fast"
 }
}
```

## Per-model thought_level choices (currentValue, options) after switching model
```json
{
 "model=swe-2-high": [
  "high",
  [
   "medium",
   "high",
   "max"
  ]
 ],
 "model=gemini-3-8-flash-medium": [
  "medium",
  [
   "low",
   "medium",
   "high"
  ]
 ],
 "model=swe-1-7-lightning-medium": [
  "medium",
  [
   "medium",
   "max"
  ]
 ],
 "model=fusion-gpt-5-6-sol-high-sidekick-swe-2-medium": [
  "high",
  [
   "low",
   "medium",
   "high",
   "xhigh",
   "max"
  ]
 ],
 "model=grok-4-7-medium": [
  "medium",
  [
   "low",
   "medium",
   "high",
   "xhigh"
  ]
 ],
 "model=claude-sonnet-5-medium": [
  "medium",
  [
   "low",
   "medium",
   "high",
   "xhigh",
   "max"
  ]
 ]
}
```

## `devin --permission-mode dangerous acp` then set_mode bypass / smart
```json
{
 "bypass": {
  "set_mode": {
   "code": -32602,
   "message": "Invalid params",
   "data": "Mode 'bypass' is restricted by your organization's policy"
  },
  "set_config_option": {
   "code": -32602,
   "message": "Invalid params",
   "data": "Mode 'bypass' is restricted by your organization's policy"
  }
 },
 "smart": {
  "set_mode": {},
  "set_config_option": {
   "configOptions": [
    {
     "id": "mode",
     "name": "Session Mode",
     "category": "mode",
     "type": "select",
     "currentValue": "smart",
     "options": [
      {
       "value": "accept-edits",
       "name": "Code",
       "description": "Write and edit code",
       "_meta": {
        "cognition.ai/icon": "code"
       }
      },
      {
       "value": "smart",
       "name": "Smart",
       "description": "Auto-approve actions the model judges safe",
       "_meta": {
        "cognition.ai/icon": "sparkles"
       }
      },
      {
       "value": "ask",
       "name": "Ask",
       "description": "Answer questions without code changes",
       "_meta": {
        "cognition.ai/icon": "message-circle"
       }
      },
      {
       "value": "plan",
       "name": "Plan",
       "description": "Plan changes before implementing",
       "_meta": {
        "cognition.ai/icon": "file-text"
       }
      }
     ]
    },
    {
     "id": "model",
     "name": "Model",
     "description": "AI model to use",
     "category": "model",
     "type": "select",
     "currentValue": "gpt-5-6-sol-medium",
```
modes after launch with flag: {"currentModeId": "accept-edits", "availableModes": [{"id": "accept-edits", "name": "Code"}, {"id": "smart", "name": "Smart"}, {"id": "ask", "name": "Ask"}, {"id": "plan", "name": "Plan"}]}

DEVIN_PERMISSION_MODE=dangerous env: modes {"currentModeId": "accept-edits", "availableModes": [{"id": "accept-edits", "name": "Code"}, {"id": "smart", "name": "Smart"}, {"id": "ask", "name": "Ask"}, {"id": "plan", "name": "Plan"}]}

`devin --sandbox acp` + set autonomous: {"autonomous": {"set_mode": {"code": -32602, "message": "Invalid params", "data": "Mode 'autonomous' is restricted by your organization's policy"}, "set_config_option": {"code": -32602, "message": "Invalid params", "data": "Mode 'autonomous' is restricted by your organization's policy"}}}

## Permission request options for a shell command (empty config, accept-edits)
```json
[
 {
  "toolCall": {
   "title": null,
   "kind": null
  },
  "options": [
   {
    "optionId": "allow_once",
    "name": "Allow",
    "kind": "allow_once"
   },
   {
    "optionId": "allow_session",
    "name": "Yes, allow `date` commands (this session)",
    "kind": "allow_always"
   },
   {
    "optionId": "allow_always",
    "name": "Yes, always allow `date` commands in `ws`",
    "kind": "allow_always"
   },
   {
    "optionId": "allow_always_global",
    "name": "Yes, always allow `date` commands in all projects",
    "kind": "allow_always"
   },
   {
    "optionId": "reject_once",
    "name": "Reject",
    "kind": "reject_once"
   }
  ]
 }
]
```

## `--config` with permissions.allow ["exec"]: no permission request; command executed (file created). permission_requests=[]

## Docker (Linux, unauthenticated, no org policy)
session/new modes: {currentModeId: accept-edits, availableModes: [accept-edits, ask, plan, bypass]} (no `smart`); set_mode bypass -> success, currentModeId bypass; set autonomous -> -32602 'restricted by your organization's policy' (sandbox inactive). Model list empty (not logged in).

## Round 2 (2026-09-23 afternoon)

### RepoPrompt MCP permission request shape (RepoPromptCE server via XDG_CONFIG_HOME/devin/mcp_config.json, empty permissions)

session/request_permission params (full):
```json
{
 "sessionId": "sugary-albacore",
 "toolCall": {
  "toolCallId": "call_wlaE17m1YsNi7diDbrLxWCyj"
 },
 "options": [
  {
   "optionId": "allow_once",
   "name": "Allow",
   "kind": "allow_once"
  },
  {
   "optionId": "allow_session",
   "name": "Yes, allow calling windows on the RepoPromptCE MCP server (this session)",
   "kind": "allow_always"
  },
  {
   "optionId": "allow_always",
   "name": "Yes, always allow calling windows on the RepoPromptCE MCP server",
   "kind": "allow_always"
  },
  {
   "optionId": "allow_server_session",
   "name": "Yes, allow calling all tools on the RepoPromptCE MCP server (this session)",
   "kind": "allow_always"
  },
  {
   "optionId": "allow_server_always",
   "name": "Yes, always allow calling tools on the RepoPromptCE MCP server",
   "kind": "allow_always"
  },
  {
   "optionId": "reject_once",
   "name": "Reject",
   "kind": "reject_once"
  }
 ]
}
```

Preceding session/update tool_call events (in order, relative to the permission request):
```json
BEFORE {"sessionUpdate": "tool_call", "toolCallId": "call_qa5Y96E01032K8gFwL2cKWrJ", "title": "Listed MCP tools for RepoPromptCE", "rawInput": {"server_name": "RepoPromptCE"}, "_meta": {"cognition.ai/inferenceToolName": "mcp_list_tools"}}
BEFORE {"sessionUpdate": "tool_call_update", "toolCallId": "call_qa5Y96E01032K8gFwL2cKWrJ", "status": "in_progress", "_meta": {"cognition.ai/inferenceToolName": "mcp_list_tools"}}
BEFORE {"sessionUpdate": "tool_call_update", "toolCallId": "call_qa5Y96E01032K8gFwL2cKWrJ", "status": "in_progress", "title": "Listed MCP tools for RepoPromptCE", "_meta": {"cognition.ai/inferenceToolName": "mcp_list_tools"}}
BEFORE {"sessionUpdate": "tool_call_update", "toolCallId": "call_qa5Y96E01032K8gFwL2cKWrJ", "status": "completed", "content": "<omitted>", "_meta": {"cognition.ai/inferenceToolName": "mcp_list_tools"}}
BEFORE {"sessionUpdate": "tool_call", "toolCallId": "call_hjgPNHcVinBq9FpQ7th2nY2P", "title": "Calling windows from RepoPromptCE", "rawInput": {}, "_meta": {"cognition.ai/toolName": "mcp__RepoPromptCE__windows", "cognition.ai/eventType": "mcp_tool_call", "cognition.ai/inferenceToolName": "mcp__RepoPromptCE__windows"}}
AFTER  {"sessionUpdate": "tool_call_update", "toolCallId": "call_hjgPNHcVinBq9FpQ7th2nY2P", "status": "failed", "content": "<omitted>", "_meta": {"cognition.ai/inferenceToolName": "mcp__RepoPromptCE__windows", "cognition.ai/rejected": true}}
```

### session/load after setting mode=smart and one prompt
load result modes.currentModeId = `smart`; configOptions current: {'mode': 'smart', 'model': 'gpt-5-6-sol-medium', 'thought_level': 'medium', 'speed': 'standard'}

### Model enumeration (initialize with _meta.parameterizedModelPicker=true)
models=69 total_ms=9173 per-model ms min/median/max=11/13/566; catalogue identical without the _meta flag (69 models).
thought_level choice sets: [["low,medium,high,xhigh,max", 30], ["none,low,medium,high,xhigh,max", 5], ["low,medium,high,xhigh", 4], ["low,medium,high", 3], ["minimal,low,medium,high", 3], ["none,low,medium,high,xhigh", 3], ["medium,max", 2], ["medium,high,max", 1], ["none,low,medium,high", 1], ["low,high", 1]]
models without thought_level: ["claude-opus-4-6", "claude-opus-4-6-thinking", "claude-opus-4-6-1m", "claude-opus-4-6-thinking-1m", "claude-sonnet-4-6", "claude-sonnet-4-6-thinking", "claude-sonnet-4-6-1m", "claude-sonnet-4-6-thinking-1m", "MODEL_CLAUDE_4_5_OPUS", "MODEL_CLAUDE_4_5_OPUS_THINKING", "MODEL_PRIVATE_11", "MODEL_PRIVATE_2", "MODEL_PRIVATE_3", "MODEL_CHAT_GPT_4_1_2025_04_14", "swe-1-6", "swe-1-6-fast"]
per-model (default, choices): ```{"claude-opus-5-5-medium": ["medium", ["low", "medium", "high", "xhigh", "max"]], "claude-sonnet-5-medium": ["medium", ["low", "medium", "high", "xhigh", "max"]], "gemini-3-8-flash-medium": ["medium", ["low", "medium", "high"]], "gpt-6-astra-medium": ["medium", ["low", "medium", "high", "xhigh", "max"]], "gpt-6-sol-medium": ["medium", ["none", "low", "medium", "high", "xhigh", "max"]], "gpt-6-luna-medium": ["medium", ["none", "low", "medium", "high", "xhigh", "max"]], "swe-1-7-lightning-medium": ["medium", ["medium", "max"]], "swe-2-high": ["high", ["medium", "high", "max"]], "claude-opus-4-7-medium": ["medium", ["low", "medium", "high", "xhigh", "max"]], "claude-opus-4-8-medium": ["medium", ["low", "medium", "high", "xhigh", "max"]], "claude-opus-5-medium": ["medium", ["low", "medium", "high", "xhigh", "max"]], "gemini-3-5-flash-medium": ["medium", ["minimal", "low", "medium", "high"]], "gemini-3-6-flash-medium": ["medium", ["minimal", "low", "medium", "high"]], "gemini-3-7-flash-medium": ["medium", ["low", "medium", "high"]], "gpt-5-6-sol-medium": ["medium", ["none", "low", "medium", "high", "xhigh", "max"]], "gpt-5-6-terra-medium": ["medium", ["none", "low", "medium", "high", "xhigh", "max"]], "gpt-5-6-luna-medium": ["medium", ["none", "low", "medium", "high", "xhigh", "max"]], "grok-4-5-medium": ["medium", ["low", "medium", "high"]], "grok-4-6-medium": ["medium", ["low", "medium", "high", "xhigh"]], "grok-4-7-medium": ["medium", ["low", "medium", "high", "xhigh"]], "swe-1-7-medium": ["medium", ["medium", "max"]], "fusion-gpt-5-6-sol-high-sidekick-swe-2-medium": ["high", ["low", "medium", "high", "xhigh", "max"]], "fusion-claude-opus-5-high-sidekick-swe-2-medium": ["high", ["low", "medium", "high", "xhigh", "max"]], "fusion-claude-opus-5-5-high-sidekick-swe-2-medium": ["high", ["low", "medium", "high", "xhigh", "max"]], "fusion-gpt-6-astra-high-sidekick-swe-2-medium": ["high", ["low", "medium", "high", "xhigh", "max"]], "fusion-gpt-6-sol-high-sidekick-swe-2-medium": ["high", ["low", "medium", "high", "xhigh", "max"]], "fusion-gpt-5-6-sol-high-sidekick-gpt-5-6-luna-high": ["high", ["low", "medium", "high", "xhigh", "max"]], "fusion-claude-opus-5-high-sidekick-gpt-5-6-luna-high": ["high", ["low", "medium", "high", "xhigh", "max"]], "fusion-claude-opus-5-5-high-sidekick-gpt-5-6-luna-high": ["high", ["low", "medium", "high", "xhigh", "max"]], "fusion-gpt-6-astra-high-sidekick-gpt-5-6-luna-high": ["high", ["low", "medium", "high", "xhigh", "max"]], "fusion-gpt-6-sol-high-sidekick-gpt-5-6-luna-high": ["high", ["low", "medium", "high", "xhigh", "max"]], "fusion-gpt-5-6-sol-high-sidekick-gpt-6-luna-high": ["high", ["low", "medium", "high", "xhigh", "max"]], "fusion-claude-opus-5-high-sidekick-gpt-6-luna-high": ["high", ["low", "medium", "high", "xhigh", "max"]], "fusion-claude-opus-5-5-high-sidekick-gpt-6-luna-high": ["high", ["low", "medium", "high", "xhigh", "max"]], "fusion-gpt-6-astra-high-sidekick-gpt-6-luna-high": ["high", ["low", "medium", "high", "xhigh", "max"]], "fusion-gpt-6-sol-high-sidekick-gpt-6-luna-high": ["high", ["low", "medium", "high", "xhigh", "max"]], "fusion-claude-opus-5-high-sidekick-gpt-5-6-sol-high": ["high", ["low", "medium", "high", "xhigh", "max"]], "fusion-claude-opus-5-5-high-sidekick-gpt-5-6-sol-high": ["high", ["low", "medium", "high", "xhigh", "max"]], "fusion-gpt-6-astra-high-sidekick-gpt-5-6-sol-high": ["high", ["low", "medium", "high", "xhigh", "max"]], "fusion-gpt-6-sol-high-sidekick-gpt-5-6-sol-high": ["high", ["low", "medium", "high", "xhigh", "max"]], "fusion-gpt-5-6-sol-high-sidekick-swe-2-high": ["high", ["low", "medium", "high", "xhigh", "max"]], "fusion-claude-opus-5-high-sidekick-swe-2-high": ["high", ["low", "medium", "high", "xhigh", "max"]], "fusion-claude-opus-5-5-high-sidekick-swe-2-high": ["high", ["low", "medium", "high", "xhigh", "max"]], "fusion-gpt-6-astra-high-sidekick-swe-2-high": ["high", ["low", "medium", "high", "xhigh", "max"]], "fusion-gpt-6-sol-high-sidekick-swe-2-high": ["high", ["low", "medium", "high", "xhigh", "max"]], "claude-opus-4-6": null, "claude-opus-4-6-thinking": null, "claude-opus-4-6-1m": null, "claude-opus-4-6-thinking-1m": null, "gpt-5-4-none": ["none", ["none", "low", "medium", "high", "xhigh"]], "gpt-5-5-low": ["low", ["none", "low", "medium", "high", "xhigh"]], "gpt-5-4-mini-low": ["low", ["low", "medium", "high", "xhigh"]], "claude-sonnet-4-6": null, "claude-sonnet-4-6-thinking": null, "claude-sonnet-4-6-1m": null, "claude-sonnet-4-6-thinking-1m": null, "MODEL_GPT_5_2_LOW": ["low", ["none", "low", "medium", "high", "xhigh"]], "MODEL_CLAUDE_4_5_OPUS": null, "MODEL_CLAUDE_4_5_OPUS_THINKING": null, "MODEL_PRIVATE_11": null, "MODEL_PRIVATE_2": null, "MODEL_PRIVATE_3": null, "MODEL_CHAT_GPT_4_1_2025_04_14": null, "MODEL_PRIVATE_12": ["none", ["none", "low", "medium", "high"]], "gpt-5-3-codex-medium": ["medium", ["low", "medium", "high", "xhigh"]], "swe-1-6": null, "swe-1-6-fast": null, "gemini-3-1-pro-low": ["low", ["low", "high"]], "MODEL_GOOGLE_GEMINI_3_0_FLASH_MINIMAL": ["minimal", ["minimal", "low", "medium", "high"]]}```

### Mode change during a running prompt
set_config_option mode=smart 4 s into the turn -> {"result": {"mode": "smart", "model": "gpt-5-6-sol-medium", "thought_level": "medium", "speed": "standard"}}; prompt stopReason=end_turn
