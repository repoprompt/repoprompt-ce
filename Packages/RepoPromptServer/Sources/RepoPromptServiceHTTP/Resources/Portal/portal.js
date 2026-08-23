"use strict";

(() => {
  const providerOrder = [
    "codex",
    "claudeCompatible",
    "claudeGLM",
    "claudeKimi",
    "claudeCustom",
    "openCodeACP",
    "cursorACP",
    "grokBuildACP",
    "openAIAPI",
    "anthropicAPI",
    "openRouter",
    "customOpenAICompatible",
    "gemini",
    "azure",
    "deepseek",
    "fireworks",
    "xAI",
    "groq",
    "zAI",
    "ollama",
  ];
  const supportedRoutes = new Set([
    "overview",
    "cli-providers",
    "agent-models",
    "agent-permissions",
    "agent-workflows",
    "context-builder",
    "portal-appearance",
    "advanced",
    "mcp-server",
    "mcp-tools",
    "workspace-approvals",
    "model-presets",
    "api-providers",
    "openrouter",
    "custom-api",
    "model-config",
    "manage-workspaces",
    "manage-presets",
  ]);
  const directAuthenticationMethods = new Set([
    "apiKey",
    "enterpriseAccessToken",
    "authToken",
    "keyHelper",
    "workloadIdentityFederation",
    "providerSpecific",
  ]);
  const transientAuthenticationMethods = new Set([
    "browserOAuth",
    "deviceCodeBeta",
    "browserLogin",
  ]);
  const terminalFlowStates = new Set([
    "completed",
    "failed",
    "cancelled",
    "expired",
  ]);
  const pollDelay = window.__REPOPROMPT_PORTAL_TEST_HOOK__ ? 60_000 : 1_600;

  const state = {
    providers: [],
    bootstrap: null,
    desktopSettings: null,
    settingsMutation: null,
    domainMutations: {},
    settingsFeedback: {
      activeCount: 0,
      outcome: null,
      message: "No changes saved yet",
    },
    typedSettings: {
      agentModels: null,
      directAgentPermissions: null,
      subagentPermissions: null,
      contextBuilder: null,
      modelPresets: null,
      advanced: null,
      workspaceApprovals: null,
      mcpDisabledTools: null,
      showModelPresets: null,
      selectionPresets: null,
      workflows: null,
      selections: {},
      directConfigurations: {},
    },
    generatedAt: null,
    route: "home",
    loading: false,
    loadPromise: null,
    online: navigator.onLine !== false,
    activeFlow: null,
    pollTimer: null,
    pollPromise: null,
    confirmResolver: null,
    confirmReturnFocus: null,
    settingsDrawerReturnFocus: null,
    focusAfterRoute: false,
    initialized: false,
    agent: {
      selectedProjectID: null,
      selectedSessionID: null,
      newSessionMode: false,
      searchText: "",
      transcriptItems: [],
      transcriptPage: null,
      transcriptPromise: null,
      transcriptPromiseSessionID: null,
      mutationPromise: null,
      pollTimer: null,
      selectionGeneration: 0,
      retryOperation: null,
    },
  };

  const appearanceCookieName = "rpce_portal_appearance";
  const appearanceThemes = new Set(["system", "light", "dark"]);
  const appearanceDensities = new Set(["normal", "large", "extraLarge"]);

  function portalAppearance() {
    const encoded = document.cookie
      .split(";")
      .map((entry) => entry.trim())
      .find((entry) => entry.startsWith(`${appearanceCookieName}=`))
      ?.slice(appearanceCookieName.length + 1);
    const [version, theme, density] = decodeURIComponent(encoded || "").split(
      ".",
    );
    return {
      theme: version === "v1" && appearanceThemes.has(theme) ? theme : "system",
      density:
        version === "v1" && appearanceDensities.has(density)
          ? density
          : "normal",
    };
  }

  function applyPortalAppearance(preference = portalAppearance()) {
    document.documentElement.dataset.portalTheme = preference.theme;
    document.documentElement.dataset.textDensity = preference.density;
  }

  function savePortalAppearance(preference) {
    beginSettingsMutation();
    try {
      const theme = appearanceThemes.has(preference.theme)
        ? preference.theme
        : "system";
      const density = appearanceDensities.has(preference.density)
        ? preference.density
        : "normal";
      document.cookie = `${appearanceCookieName}=${encodeURIComponent(`v1.${theme}.${density}`)}; Path=/portal; SameSite=Strict; Secure`;
      applyPortalAppearance({ theme, density });
      finishSettingsMutation();
    } catch (error) {
      finishSettingsMutation(error);
      toast(error.message || "Browser appearance could not be saved.", true);
    }
  }

  // Hand-authored web-safe semantic line glyphs substitute for non-portable
  // SF Symbols without copying Apple artwork.
  const icons = {
    search: '<circle cx="7" cy="7" r="4.5"/><path d="m10.5 10.5 3.5 3.5"/>',
    refresh: '<path d="M13 5V2l-2 2a5.5 5.5 0 1 0 1.2 7.8"/>',
    settings:
      '<path d="M14.7 9V7l-1.8-.6-.4-1 .9-1.7L12 2.3l-1.7.9-1-.4L8.7 1h-2l-.6 1.8-1 .4-1.7-.9L2 3.7l.9 1.7-.4 1L.7 7v2l1.8.6.4 1-.9 1.7 1.4 1.4 1.7-.9 1 .4.6 1.8h2l.6-1.8 1-.4 1.7.9 1.4-1.4-.9-1.7.4-1z"/><circle cx="7.7" cy="8" r="2.2"/>',
    message: '<path d="M2 3.5h12v8H7l-3.5 2v-2H2z"/>',
    folder: '<path d="M1.5 4h5l1.4 1.5h6.6v7.5h-13z"/>',
    workflow:
      '<circle cx="4" cy="3" r="1.5"/><circle cx="12" cy="8" r="1.5"/><circle cx="4" cy="13" r="1.5"/><path d="M5.5 3h2A2.5 2.5 0 0 1 10 5.5V8M5.5 13h2A2.5 2.5 0 0 0 10 10.5V8"/>',
    bolt: '<path d="M9 1.5 3.5 8H8l-1 6.5L12.5 7H8z"/>',
    sparkles:
      '<path d="M5 1.5c.3 2.1 1.4 3.2 3.5 3.5C6.4 5.3 5.3 6.4 5 8.5 4.7 6.4 3.6 5.3 1.5 5 3.6 4.7 4.7 3.6 5 1.5zM11.5 8c.2 1.6 1.1 2.5 2.7 2.7-1.6.2-2.5 1.1-2.7 2.7-.2-1.6-1.1-2.5-2.7-2.7 1.6-.2 2.5-1.1 2.7-2.7z"/>',
    model: '<path d="M8 1.5 14 5v6l-6 3.5L2 11V5zM2 5l6 3.5L14 5M8 8.5v6"/>',
    shield:
      '<path d="M8 1.5 13 3v4.3c0 3.2-2 5.7-5 7.2-3-1.5-5-4-5-7.2V3z"/><path d="m5.5 8 1.5 1.5 3.5-4"/>',
    chevron: '<path d="m6 3 5 5-5 5"/>',
    terminal: '<path d="M1.5 3h13v10h-13zM4 6l2 2-2 2M8 10h3"/>',
    agent:
      '<circle cx="8" cy="5" r="3"/><path d="M2.5 14c.5-3 2.4-4.5 5.5-4.5s5 1.5 5.5 4.5"/>',
    brain:
      '<path d="M6.5 2.2A2.5 2.5 0 0 0 2.8 5a2.7 2.7 0 0 0 .4 4.8 2.5 2.5 0 0 0 3.3 3.1V2.2zM9.5 2.2A2.5 2.5 0 0 1 13.2 5a2.7 2.7 0 0 1-.4 4.8 2.5 2.5 0 0 1-3.3 3.1V2.2zM6.5 5H5M9.5 7H11M6.5 10H5.2M9.5 11h1.2"/>',
    appearance: '<circle cx="8" cy="8" r="6"/><path d="M8 2a6 6 0 0 0 0 12z"/>',
    keyboard:
      '<path d="M1.5 4h13v8h-13zM4 7h.1M7 7h.1M10 7h.1M12 7h.1M4 10h8"/>',
    sliders: '<path d="M2 4h12M2 8h12M2 12h12M5 2v4M11 6v4M7 10v4"/>',
    key: '<circle cx="5" cy="7" r="3"/><path d="m7.3 9.3 5.2 5.2M10 12l1.5-1.5M8.5 10.5 10 9"/>',
    network:
      '<circle cx="8" cy="8" r="6"/><path d="M2 8h12M8 2c2 1.7 3 3.7 3 6s-1 4.3-3 6c-2-1.7-3-3.7-3-6s1-4.3 3-6z"/>',
    stack:
      '<rect x="2" y="3" width="12" height="9" rx="1"/><path d="M4 1.5h8M4 14.5h8"/>',
    listStar:
      '<path d="M2 3h6M2 7h5M2 11h6"/><path d="m11.5 7 .7 1.5 1.7.2-1.2 1.2.3 1.7-1.5-.8-1.5.8.3-1.7-1.2-1.2 1.7-.2z"/>',
    sidebar:
      '<rect x="1.5" y="2" width="13" height="12" rx="1.5"/><path d="M5.5 2v12"/>',
    context:
      '<path d="M2 3h12v10H2zM5 6h6M5 9h4"/><path d="M1 5V2h3M15 5V2h-3M1 11v3h3M15 11v3h-3"/>',
    server:
      '<rect x="2" y="2" width="12" height="5" rx="1"/><rect x="2" y="9" width="12" height="5" rx="1"/><circle cx="5" cy="4.5" r=".6" fill="currentColor"/><circle cx="5" cy="11.5" r=".6" fill="currentColor"/>',
    cloud:
      '<path d="M4.5 12.5H12a3 3 0 0 0 .4-6A4.5 4.5 0 0 0 4 5.5a3.5 3.5 0 0 0 .5 7z"/>',
    back: '<path d="m9.5 3-5 5 5 5M5 8h9"/>',
    info: '<circle cx="8" cy="8" r="6"/><path d="M8 7v4M8 4.5h.01"/>',
    warning: '<path d="M8 1.5 15 14H1zM8 6v3.5M8 12h.01"/>',
    close: '<path d="m3 3 10 10M13 3 3 13"/>',
    check: '<path d="m2.5 8 3.5 3.5 7.5-7.5"/>',
    link: '<path d="M6.5 9.5 9.5 6.5M5 11H3.5a2.5 2.5 0 0 1 0-5H6M10 5h2.5a2.5 2.5 0 0 1 0 5H10"/>',
    send: '<path d="M1.5 8 14.5 2 10 14l-2-5zM8 9l6.5-7"/>',
  };

  class PortalError extends Error {
    constructor(message, options = {}) {
      super(message);
      this.name = "PortalError";
      this.status = options.status || 0;
      this.code = options.code || null;
      this.retryable = options.retryable === true;
      this.network = options.network === true;
    }
  }

  function element(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  function iconNode(name, className) {
    const node = element("span", className);
    node.dataset.icon = name;
    node.setAttribute("aria-hidden", "true");
    return node;
  }

  function installIcons(root = document) {
    root.querySelectorAll("[data-icon]").forEach((node) => {
      const content = icons[node.dataset.icon];
      if (!content || node.querySelector("svg")) return;
      node.insertAdjacentHTML(
        "afterbegin",
        `<svg viewBox="0 0 16 16" aria-hidden="true">${content}</svg>`,
      );
    });
  }

  function humanize(value) {
    const labels = {
      browserOAuth: "Browser OAuth",
      deviceCodeBeta: "Device auth (beta)",
      apiKey: "API key",
      enterpriseAccessToken: "Enterprise access token",
      authToken: "Auth token",
      keyHelper: "Key helper",
      workloadIdentityFederation: "Workload identity federation",
      browserLogin: "Browser login",
      providerSpecific: "Provider-specific authentication",
      notConfigured: "Not configured",
      notTested: "Not tested",
      deploymentDisabled: "Deployment disabled",
      missingExecutable: "Missing executable",
      missingCredential: "Missing credential",
      invalidCredential: "Invalid credential",
      authenticationPending: "Authentication pending",
      unsupportedModel: "Unsupported model",
      unsupportedControl: "Unsupported control",
      runtimeUnavailable: "Runtime unavailable",
      xhigh: "XHigh",
      max: "Max",
      ultra: "Ultra",
    };
    return (
      labels[value] ||
      String(value || "")
        .replace(/([a-z])([A-Z])/g, "$1 $2")
        .replace(/^./, (character) => character.toUpperCase())
    );
  }

  function formatDate(value, fallback = "—") {
    if (!value) return fallback;
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) return fallback;
    return new Intl.DateTimeFormat(undefined, {
      dateStyle: "medium",
      timeStyle: "short",
    }).format(date);
  }

  function announce(message) {
    const announcer = document.getElementById("announcer");
    announcer.textContent = "";
    window.setTimeout(() => {
      announcer.textContent = message;
    }, 0);
  }

  function toast(message, isError = false) {
    const node = element("div", `toast${isError ? " error" : ""}`, message);
    document.getElementById("toast-region").append(node);
    window.setTimeout(() => node.remove(), 4_200);
  }

  function renderSettingsFeedback() {
    const node = document.getElementById("settings-save-status");
    if (!node) return;
    const feedback = state.settingsFeedback;
    const phase =
      feedback.outcome === "error"
        ? "error"
        : feedback.activeCount > 0
          ? "saving"
          : feedback.outcome || "idle";
    node.dataset.state = phase;
    node.textContent = feedback.message;
    node.setAttribute("role", phase === "error" ? "alert" : "status");
    node.setAttribute("aria-live", phase === "error" ? "assertive" : "polite");
  }

  function beginSettingsMutation() {
    const feedback = state.settingsFeedback;
    if (feedback.activeCount === 0) feedback.outcome = null;
    feedback.activeCount += 1;
    if (feedback.outcome !== "error") feedback.message = "Saving…";
    renderSettingsFeedback();
    announce("Saving settings");
  }

  function finishSettingsMutation(error = null) {
    const feedback = state.settingsFeedback;
    feedback.activeCount = Math.max(0, feedback.activeCount - 1);
    if (error) {
      feedback.outcome = "error";
      feedback.message = `Save failed: ${error.message || "The change was not saved."} Review the setting and try again.`;
    } else if (feedback.activeCount === 0 && feedback.outcome !== "error") {
      feedback.outcome = "saved";
      feedback.message = "Saved";
    } else if (feedback.activeCount > 0 && feedback.outcome !== "error") {
      feedback.message = "Saving…";
    }
    renderSettingsFeedback();
    announce(feedback.message);
  }

  function isSettingsMutationPath(path, method) {
    if (!["POST", "PUT", "PATCH", "DELETE"].includes(method)) return false;
    return (
      path === "api/v1/desktop-settings" ||
      /^api\/v1\/settings\//.test(path) ||
      /^api\/v1\/projects\/[^/]+\/settings\//.test(path) ||
      /^api\/v1\/provider-settings\//.test(path) ||
      /^api\/v1\/provider-auth-flows\//.test(path) ||
      /^api\/v1\/workflows(?:\/|$)/.test(path) ||
      /^api\/v1\/projects\/[^/]+\/selection-presets(?:\/|$)/.test(path)
    );
  }

  async function api(path, options = {}) {
    const method = (options.method || "GET").toUpperCase();
    const mutation = ["POST", "PUT", "PATCH", "DELETE"].includes(method);
    const reportsSettingsFeedback = isSettingsMutationPath(path, method);
    if (reportsSettingsFeedback) beginSettingsMutation();
    try {
      let response;
      try {
        response = await fetch(path, {
          cache: "no-store",
          credentials: "same-origin",
          ...options,
          method,
          headers: {
            Accept: "application/json",
            ...(options.body ? { "Content-Type": "application/json" } : {}),
            ...(mutation ? { "X-RepoPrompt-Portal-CSRF": "1" } : {}),
            ...(options.headers || {}),
          },
        });
      } catch (_error) {
        throw new PortalError(
          "Cannot reach the RepoPrompt server. Check the connection and try again.",
          {
            network: true,
            retryable: true,
          },
        );
      }

      const contentType = response.headers.get("content-type") || "";
      const text = response.status === 204 ? "" : await response.text();
      let body = null;
      if (text && contentType.includes("application/json")) {
        try {
          body = JSON.parse(text);
        } catch (_error) {
          throw new PortalError("The server returned an unreadable response.", {
            status: response.status,
          });
        }
      }
      if (!response.ok) {
        throw new PortalError(
          body?.message || `Request failed (${response.status}).`,
          {
            status: response.status,
            code: body?.code,
            retryable: body?.retryable,
          },
        );
      }
      if (reportsSettingsFeedback) finishSettingsMutation();
      return body;
    } catch (error) {
      if (reportsSettingsFeedback) finishSettingsMutation(error);
      throw error;
    }
  }

  function orderedProviders() {
    return providerOrder
      .map((id) =>
        state.providers.find((provider) => provider.providerID === id),
      )
      .filter(Boolean);
  }

  function replaceProvider(provider) {
    const index = state.providers.findIndex(
      (item) => item.providerID === provider.providerID,
    );
    if (index >= 0) state.providers[index] = provider;
    else state.providers.push(provider);
    state.generatedAt = new Date().toISOString();
  }

  function providerDestination(provider) {
    return provider.category === "apiProvider"
      ? "api-providers"
      : "cli-providers";
  }

  function desktopProviderPresentation(provider) {
    const presentations = {
      codex: {
        title: "Codex CLI",
        subtitle:
          "Runs RepoPrompt CE's managed Codex runtime with a separate sign-in from ~/.codex.",
      },
      claudeCompatible: {
        title: "Claude Code CLI",
        subtitle:
          "Uses your Claude Code CLI login for Anthropic models. Compatible backends use their own API keys.",
      },
      claudeGLM: {
        title: settingValue("claudeGLMDisplayName", provider.displayName),
        subtitle: `Claude Code routed through Z.ai. Haiku → ${settingValue("claudeGLMHaikuModel")} · Sonnet → ${settingValue("claudeGLMSonnetModel")} · Opus → ${settingValue("claudeGLMOpusModel")}.`,
      },
      claudeKimi: {
        title: settingValue("claudeKimiDisplayName", provider.displayName),
        subtitle:
          "Claude Code routed through Kimi's coding backend. RepoPrompt does not pass --model.",
      },
      claudeCustom: {
        title: settingValue("claudeCustomDisplayName", provider.displayName),
        subtitle:
          "Your own configurable Claude Code-compatible HTTPS endpoint.",
      },
      openCodeACP: {
        title: "OpenCode CLI",
        subtitle:
          "Uses OpenCode's ACP runtime for Agent Mode; headless OpenCode runs use a managed no-native-tools mode.",
      },
      cursorACP: {
        title: "Cursor CLI",
        subtitle:
          "Uses Cursor's ACP runtime for Agent Mode, headless tasks, and chat.",
      },
      grokBuildACP: {
        title: "Grok Build CLI",
        subtitle:
          "Uses Grok Build's ACP runtime for Agent Mode, headless tasks, and chat.",
      },
    };
    return (
      presentations[provider.providerID] || {
        title: provider.displayName,
        subtitle: provider.summary,
      }
    );
  }

  function providerStatus(provider) {
    const connectionFailed =
      provider.connection?.state === "attention" ||
      ["invalid", "unavailable"].includes(provider.connection?.testState) ||
      provider.authentication?.state === "attention" ||
      provider.preflight?.reason === "invalidCredential";
    if (connectionFailed) {
      return {
        label:
          provider.connection?.detail ||
          provider.authentication?.detail ||
          "Connection failed",
        tone: "attention",
      };
    }
    if (
      provider.authentication?.authenticated &&
      provider.connection?.testState === "valid"
    ) {
      return { label: "Connected", tone: "connected" };
    }
    return { label: "Not configured", tone: "" };
  }

  function setDisabledReason(control, disabled, reason) {
    control.disabled = disabled;
    if (disabled && reason) {
      control.title = reason;
      control.dataset.disabledReason = reason;
    } else {
      control.removeAttribute("data-disabled-reason");
      control.removeAttribute("title");
    }
  }

  function setConnectionPresentation(kind, message) {
    const dot = document.getElementById("service-dot");
    const banner = document.getElementById("connection-banner");
    const bannerText = document.getElementById("connection-banner-text");
    dot.classList.remove("online", "stale", "offline");
    dot.classList.add(kind);
    banner.hidden = kind === "online";
    bannerText.textContent = message || "";
    state.online = kind !== "offline";
  }

  function setLoading(loading) {
    const refresh = document.getElementById("refresh-button");
    state.loading = loading;
    refresh.classList.toggle("loading", loading);
    refresh.setAttribute("aria-busy", String(loading));
    setDisabledReason(refresh, loading, "Refresh is already in progress.");
    document
      .getElementById("session-list")
      .setAttribute("aria-busy", String(loading));
    document
      .getElementById("settings-content")
      .setAttribute("aria-busy", String(loading));
  }

  function renderInitialLoading() {
    const projects = document.getElementById("project-list");
    const sessions = document.getElementById("session-list");
    projects.replaceChildren(
      element("div", "sidebar-loading", "Loading projects…"),
    );
    sessions.replaceChildren(
      element("div", "sidebar-loading", "Loading sessions…"),
    );
    document
      .getElementById("transcript-list")
      .replaceChildren(
        element("div", "transcript-empty", "Loading workspace…"),
      );
    const content = document.getElementById("settings-content");
    content.replaceChildren(
      element("div", "empty-state-panel", "Loading provider settings…"),
    );
  }

  async function loadSettingsDomain(domain) {
    const projectID = state.agent.selectedProjectID;
    const sessionID = state.agent.selectedSessionID;
    switch (domain) {
      case "agentModels":
        state.typedSettings.agentModels = await api(
          projectID
            ? `api/v1/projects/${encodeURIComponent(projectID)}/settings/agent-models`
            : "api/v1/settings/agent-models",
        );
        break;
      case "directAgentPermissions":
        state.typedSettings.directAgentPermissions = await api(
          "api/v1/settings/direct-agent-permissions",
        );
        break;
      case "subagentPermissions":
        state.typedSettings.subagentPermissions = await api(
          "api/v1/settings/subagent-permissions",
        );
        break;
      case "contextBuilder":
        state.typedSettings.contextBuilder = await api(
          projectID
            ? `api/v1/projects/${encodeURIComponent(projectID)}/settings/context-builder`
            : "api/v1/settings/context-builder",
        );
        break;
      case "modelPresets":
        state.typedSettings.modelPresets = await api(
          "api/v1/settings/model-presets",
        );
        break;
      case "advanced":
        state.typedSettings.advanced = await api("api/v1/settings/advanced");
        break;
      case "workspaceApprovals":
        state.typedSettings.workspaceApprovals = await api(
          "api/v1/settings/workspace-approvals",
        );
        break;
      case "mcpDisabledTools":
        state.typedSettings.mcpDisabledTools = await api(
          "api/v1/settings/mcp-disabled-tools",
        );
        break;
      case "showModelPresets":
        state.typedSettings.showModelPresets = await api(
          "api/v1/settings/show-model-presets",
        );
        break;
      case "selectionPresets":
        state.typedSettings.selectionPresets = projectID
          ? await api(
              `api/v1/projects/${encodeURIComponent(projectID)}/selection-presets`,
            )
          : null;
        break;
      case "workflows":
        applyWorkflowRepository(await api("api/v1/workflows"));
        break;
      case "selection":
        if (sessionID) {
          state.typedSettings.selections[sessionID] = await api(
            `api/v1/sessions/${encodeURIComponent(sessionID)}/selection`,
          );
        }
        break;
      case "directConfigurations": {
        const configurations = {};
        await Promise.all(
          orderedProviders()
            .filter(
              (provider) =>
                provider.category === "apiProvider" &&
                provider.deploymentAllowed,
            )
            .map(async (provider) => {
              configurations[provider.providerID] = await api(
                `api/v1/provider-settings/${encodeURIComponent(provider.providerID)}/direct-configuration`,
              );
            }),
        );
        state.typedSettings.directConfigurations = configurations;
        break;
      }
      default:
        throw new PortalError(`Unknown settings domain: ${domain}`);
    }
  }

  function applyWorkflowRepository(value) {
    state.typedSettings.workflows = value;
    if (!value || !Array.isArray(value.workflows)) return;
    state.bootstrap ||= { projects: [], sessions: [], workflows: [] };
    state.bootstrap.workflows = value.workflows.filter(
      (workflow) => workflow.enabled && workflow.visible,
    );
    state.bootstrap.workflowRepositoryRevision = value.revision;
    if (typeof value.includeSessionCleanupGuidance === "boolean") {
      state.bootstrap.includeSessionCleanupGuidance =
        value.includeSessionCleanupGuidance;
    }
  }

  async function loadTypedSettings() {
    await Promise.all([
      loadSettingsDomain("agentModels"),
      loadSettingsDomain("directAgentPermissions"),
      loadSettingsDomain("subagentPermissions"),
      loadSettingsDomain("contextBuilder"),
      loadSettingsDomain("modelPresets"),
      loadSettingsDomain("advanced"),
      loadSettingsDomain("workspaceApprovals"),
      loadSettingsDomain("mcpDisabledTools"),
      loadSettingsDomain("showModelPresets"),
      loadSettingsDomain("selectionPresets"),
      loadSettingsDomain("workflows"),
      loadSettingsDomain("selection"),
      loadSettingsDomain("directConfigurations"),
    ]);
  }

  async function mutateDomain(domain, control, operation, applyResult) {
    if (state.domainMutations[domain]) return state.domainMutations[domain];
    if (control) setDisabledReason(control, true, "Saving…");
    state.domainMutations[domain] = (async () => {
      try {
        const result = await operation();
        applyResult(result);
        renderRoute();
        return result;
      } catch (error) {
        toast(error.message, true);
        if (error.code === "staleRevision") {
          await loadSettingsDomain(domain);
        }
        renderRoute();
        return null;
      } finally {
        state.domainMutations[domain] = null;
      }
    })();
    return state.domainMutations[domain];
  }

  async function loadAll(refresh = false) {
    if (state.loadPromise) return state.loadPromise;
    setLoading(true);
    state.loadPromise = (async () => {
      try {
        const [bootstrap, providerCatalog, desktopSettings] = await Promise.all(
          [
            api("api/v1/bootstrap"),
            api(`api/v1/provider-settings${refresh ? "?refresh=true" : ""}`),
            api("api/v1/desktop-settings"),
          ],
        );
        if (!providerCatalog || !Array.isArray(providerCatalog.providers)) {
          throw new PortalError("The provider catalog response is incomplete.");
        }
        state.bootstrap = bootstrap || {
          projects: [],
          sessions: [],
          workflows: [],
        };
        state.bootstrap.projects ||= [];
        state.bootstrap.sessions ||= [];
        state.bootstrap.workflows ||= [];
        state.providers = providerCatalog.providers;
        state.desktopSettings = desktopSettings;
        reconcileAgentSelection();
        await loadTypedSettings();
        state.generatedAt =
          providerCatalog.generatedAt || new Date().toISOString();
        document.getElementById("service-caption").textContent =
          "Connected · authenticated portal";
        setConnectionPresentation("online", "");
        updateShell();
        renderHomeProviders();
        renderRoute();
        if (state.route === "home" && state.agent.selectedSessionID) {
          await loadTranscript({ silent: true });
        }
        if (refresh) {
          toast("Server state refreshed");
          announce("Server state refreshed");
        }
      } catch (error) {
        const offline = error.network || navigator.onLine === false;
        document.getElementById("service-caption").textContent = offline
          ? "Server connection unavailable"
          : "Server state may be stale";
        setConnectionPresentation(
          offline ? "offline" : "stale",
          offline ? "The server is offline or unreachable." : error.message,
        );
        if (!state.providers.length) {
          renderHomeError(error);
          if (!document.getElementById("settings-shell").hidden)
            renderPageError(error);
        }
        toast(error.message, true);
        announce(error.message);
      } finally {
        setLoading(false);
        state.loadPromise = null;
      }
    })();
    return state.loadPromise;
  }

  function updateShell() {
    const project = selectedProject() || state.bootstrap?.projects?.[0];
    document.getElementById("active-workspace-name").textContent =
      project?.name || "RepoPrompt Server";
    const freshness = state.generatedAt
      ? `Updated ${formatDate(state.generatedAt)}`
      : "Not yet loaded";
    document.getElementById("catalog-freshness").textContent = freshness;
    renderSettingsFeedback();
  }

  function selectedProject() {
    return state.bootstrap?.projects?.find(
      (project) => project.projectId === state.agent.selectedProjectID,
    );
  }

  function selectedSession() {
    return state.bootstrap?.sessions?.find(
      (session) => session.sessionId === state.agent.selectedSessionID,
    );
  }

  function eligibleSessionProviders() {
    return orderedProviders().filter(
      (provider) =>
        provider.category === "cliProvider" &&
        provider.deploymentAllowed &&
        provider.effectiveEnabled,
    );
  }

  function reconcileAgentSelection() {
    const projects = state.bootstrap?.projects || [];
    if (
      !projects.some((item) => item.projectId === state.agent.selectedProjectID)
    ) {
      state.agent.selectedProjectID =
        projects.find((item) => item.state === "active")?.projectId ||
        projects[0]?.projectId ||
        null;
    }
    const sessions = (state.bootstrap?.sessions || []).filter(
      (item) => item.projectId === state.agent.selectedProjectID,
    );
    if (
      !sessions.some((item) => item.sessionId === state.agent.selectedSessionID)
    ) {
      state.agent.selectedSessionID =
        [...sessions].sort(
          (left, right) =>
            new Date(right.lastActivityAt || 0) -
              new Date(left.lastActivityAt || 0) ||
            left.sessionId.localeCompare(right.sessionId),
        )[0]?.sessionId || null;
      state.agent.newSessionMode = !state.agent.selectedSessionID;
    }
  }

  function renderHomeProviders() {
    reconcileAgentSelection();
    renderProjects();
    renderSessions();
    renderAgentDetail();
  }

  function renderProjects() {
    const list = document.getElementById("project-list");
    list.replaceChildren();
    const projects = state.bootstrap?.projects || [];
    if (!projects.length) {
      list.append(
        element("div", "sidebar-empty", "No projects are available."),
      );
    }
    projects.forEach((project) => {
      const button = element("button", "project-row");
      button.type = "button";
      button.dataset.projectId = project.projectId;
      button.dataset.action = "select-project";
      button.classList.toggle(
        "active",
        project.projectId === state.agent.selectedProjectID,
      );
      button.setAttribute(
        "aria-pressed",
        String(project.projectId === state.agent.selectedProjectID),
      );
      const glyph = iconNode("folder", "project-row-icon");
      const copy = element("span", "project-row-copy");
      copy.append(
        element("strong", "", project.name),
        element(
          "small",
          "",
          project.rootNames?.length
            ? project.rootNames.join(" · ")
            : humanize(project.state),
        ),
      );
      button.append(glyph, copy);
      button.addEventListener("click", () => selectProject(project.projectId));
      list.append(button);
    });
    const newChat = document.getElementById("new-chat-button");
    const reason = !projects.length
      ? "Create a project through an authorized RepoPrompt client first."
      : !eligibleSessionProviders().length
        ? "Connect and validate a CLI provider before starting a chat."
        : "";
    setDisabledReason(newChat, Boolean(reason), reason);
    installIcons(list);
  }

  function sessionDepths(sessions) {
    const byID = new Map(
      sessions.map((session) => [session.sessionId, session]),
    );
    const depthByID = new Map();
    function resolve(session, visiting = new Set()) {
      if (depthByID.has(session.sessionId))
        return depthByID.get(session.sessionId);
      if (!session.parentSessionId || !byID.has(session.parentSessionId)) {
        depthByID.set(session.sessionId, 0);
        return 0;
      }
      if (visiting.has(session.sessionId)) {
        depthByID.set(session.sessionId, 0);
        return 0;
      }
      visiting.add(session.sessionId);
      const depth = Math.min(
        6,
        resolve(byID.get(session.parentSessionId), visiting) + 1,
      );
      visiting.delete(session.sessionId);
      depthByID.set(session.sessionId, depth);
      return depth;
    }
    sessions.forEach((session) => resolve(session));
    return depthByID;
  }

  function renderSessions() {
    const list = document.getElementById("session-list");
    list.replaceChildren();
    const query = state.agent.searchText.trim().toLowerCase();
    let sessions = (state.bootstrap?.sessions || []).filter(
      (session) => session.projectId === state.agent.selectedProjectID,
    );
    const depthByID = sessionDepths(sessions);
    sessions = sessions
      .filter((session) => {
        if (!query) return true;
        return [session.title, session.provider, session.model]
          .filter(Boolean)
          .some((value) => String(value).toLowerCase().includes(query));
      })
      .sort(
        (left, right) =>
          new Date(right.lastActivityAt || 0) -
            new Date(left.lastActivityAt || 0) ||
          left.sessionId.localeCompare(right.sessionId),
      );
    document.getElementById("session-count").textContent = String(
      sessions.length,
    );
    if (!sessions.length) {
      list.append(
        element(
          "div",
          "sidebar-empty",
          query
            ? "No matching sessions."
            : "No sessions yet. Start a new chat.",
        ),
      );
    }
    sessions.forEach((session) => {
      const depth = depthByID.get(session.sessionId) || 0;
      const button = element("button", `session-row depth-${depth}`);
      button.type = "button";
      button.dataset.sessionId = session.sessionId;
      button.dataset.action = "select-session";
      const active =
        !state.agent.newSessionMode &&
        session.sessionId === state.agent.selectedSessionID;
      button.classList.toggle("active", active);
      if (active) button.setAttribute("aria-current", "true");
      const plate = element("span", `session-status-plate ${session.state}`);
      plate.setAttribute("aria-hidden", "true");
      plate.append(element("i"));
      const copy = element("span", "session-row-copy");
      copy.append(
        element("strong", "", session.title || "Agent Session"),
        element(
          "small",
          "",
          `${humanize(session.provider)}${session.model ? ` · ${session.model}` : ""}`,
        ),
      );
      button.append(
        plate,
        copy,
        element("span", "session-row-state", humanize(session.state)),
      );
      button.addEventListener("click", () => selectSession(session.sessionId));
      list.append(button);
    });
    list.setAttribute("aria-busy", "false");
  }

  function selectProject(projectID) {
    if (state.agent.selectedProjectID === projectID) return;
    clearAgentPoll();
    state.agent.selectedProjectID = projectID;
    state.agent.selectedSessionID = null;
    state.agent.transcriptItems = [];
    state.agent.transcriptPage = null;
    state.agent.newSessionMode = false;
    reconcileAgentSelection();
    renderHomeProviders();
    updateShell();
    Promise.all([
      loadSettingsDomain("agentModels"),
      loadSettingsDomain("contextBuilder"),
      loadSettingsDomain("selectionPresets"),
      loadSettingsDomain("selection"),
    ])
      .then(renderRoute)
      .catch((error) => toast(error.message, true));
    if (state.agent.selectedSessionID) loadTranscript();
  }

  function selectSession(sessionID) {
    if (
      state.agent.selectedSessionID === sessionID &&
      !state.agent.newSessionMode
    )
      return;
    clearAgentPoll();
    state.agent.selectedSessionID = sessionID;
    state.agent.newSessionMode = false;
    state.agent.transcriptItems = [];
    state.agent.transcriptPage = null;
    state.agent.selectionGeneration += 1;
    renderHomeProviders();
    loadSettingsDomain("selection").catch((error) =>
      toast(error.message, true),
    );
    loadTranscript();
  }

  function beginNewSession() {
    clearAgentPoll();
    state.agent.newSessionMode = true;
    state.agent.selectedSessionID = null;
    state.agent.transcriptItems = [];
    state.agent.transcriptPage = null;
    state.agent.selectionGeneration += 1;
    renderHomeProviders();
    document.getElementById("composer-text").focus({ preventScroll: true });
  }

  function renderAgentDetail() {
    const session = selectedSession();
    const title = document.getElementById("active-session-title");
    const metadata = document.getElementById("session-metadata");
    const stateDot = document.getElementById("session-state-dot");
    stateDot.className = "session-state-dot";
    if (state.agent.newSessionMode) {
      title.textContent = "New chat";
      metadata.replaceChildren(
        element(
          "span",
          "metadata-pill",
          selectedProject()?.name || "No project",
        ),
      );
      stateDot.classList.add("idle");
    } else if (session) {
      title.textContent = session.title || "Agent Session";
      metadata.replaceChildren(
        element("span", "metadata-pill", humanize(session.provider)),
        element("span", "metadata-pill", session.model || "Provider default"),
        element(
          "span",
          `metadata-pill state-${session.state}`,
          humanize(session.state),
        ),
      );
      stateDot.classList.add(session.state);
    } else {
      title.textContent = "What are we building?";
      metadata.replaceChildren();
      stateDot.classList.add("idle");
    }
    renderTranscript();
    renderAgentComposer();
  }

  function renderTranscript() {
    const list = document.getElementById("transcript-list");
    const status = document.getElementById("transcript-status");
    const earlier = document.getElementById("load-earlier-button");
    list.replaceChildren();
    status.textContent = "";
    earlier.hidden = !state.agent.transcriptPage?.hasMoreBefore;
    if (state.agent.newSessionMode || !state.agent.selectedSessionID) {
      const empty = element("div", "agent-welcome");
      const brand = document.createElement("img");
      brand.src = "assets/repoprompt-icon.png";
      brand.alt = "";
      empty.append(
        brand,
        element("h2", "", "What are we building?"),
        element(
          "p",
          "",
          "Choose a connected provider, describe the task, and RepoPrompt will start an authoritative server session.",
        ),
      );
      list.append(empty);
      list.setAttribute("aria-busy", "false");
      return;
    }
    if (!state.agent.transcriptItems.length) {
      list.append(
        element(
          "div",
          "transcript-empty",
          state.agent.transcriptPromise
            ? "Loading transcript…"
            : "This session has no transcript yet.",
        ),
      );
    }
    state.agent.transcriptItems.forEach((item) => {
      const row = element("article", `transcript-entry kind-${item.kind}`);
      row.dataset.entryId = item.entryId;
      const header = element("header", "transcript-entry-header");
      const role =
        item.kind === "human"
          ? "You"
          : item.kind === "assistant"
            ? "RepoPrompt"
            : humanize(item.kind);
      header.append(
        element("strong", "", role),
        element("time", "", formatDate(item.timestamp)),
      );
      const content = element("div", "transcript-entry-content", item.content);
      row.append(header, content);
      if (item.truncated)
        row.append(
          element(
            "small",
            "transcript-truncated",
            "Entry truncated by the portal safety bound.",
          ),
        );
      list.append(row);
    });
    list.setAttribute(
      "aria-busy",
      String(Boolean(state.agent.transcriptPromise)),
    );
  }

  function mergeTranscriptItems(items, prepend = false) {
    const merged = new Map(
      (prepend
        ? items.concat(state.agent.transcriptItems)
        : state.agent.transcriptItems.concat(items)
      ).map((item) => [item.entryId, item]),
    );
    state.agent.transcriptItems = [...merged.values()].sort(
      (left, right) => left.sessionSequence - right.sessionSequence,
    );
  }

  async function loadTranscript({
    before = null,
    after = null,
    silent = false,
  } = {}) {
    const sessionID = state.agent.selectedSessionID;
    if (!sessionID || state.agent.newSessionMode) return null;
    if (
      state.agent.transcriptPromise &&
      state.agent.transcriptPromiseSessionID === sessionID
    )
      return state.agent.transcriptPromise;
    const generation = state.agent.selectionGeneration;
    const query = new URLSearchParams({ limit: "200" });
    if (before !== null) query.set("beforeSequence", String(before));
    if (after !== null) query.set("afterSequence", String(after));
    const requestPromise = (async () => {
      if (!silent) renderTranscript();
      try {
        const page = await api(
          `api/v1/sessions/${encodeURIComponent(sessionID)}/transcript?${query}`,
        );
        if (
          generation !== state.agent.selectionGeneration ||
          sessionID !== state.agent.selectedSessionID
        )
          return null;
        state.agent.transcriptPage = page;
        mergeTranscriptItems(page.items || [], before !== null);
        const index = state.bootstrap.sessions.findIndex(
          (item) => item.sessionId === sessionID,
        );
        if (index >= 0) state.bootstrap.sessions[index] = page.session;
        renderSessions();
        renderAgentDetail();
        scheduleAgentPoll();
        return page;
      } catch (error) {
        if (generation === state.agent.selectionGeneration) {
          document.getElementById("transcript-status").textContent =
            `${error.message} Showing the last loaded transcript.`;
          toast(error.message, true);
          scheduleAgentPoll();
        }
        return null;
      } finally {
        if (state.agent.transcriptPromise === requestPromise) {
          state.agent.transcriptPromise = null;
          state.agent.transcriptPromiseSessionID = null;
        }
        if (
          generation === state.agent.selectionGeneration &&
          sessionID === state.agent.selectedSessionID
        )
          document
            .getElementById("transcript-list")
            .setAttribute("aria-busy", "false");
      }
    })();
    state.agent.transcriptPromise = requestPromise;
    state.agent.transcriptPromiseSessionID = sessionID;
    return requestPromise;
  }

  function clearAgentPoll() {
    if (state.agent.pollTimer !== null) {
      window.clearTimeout(state.agent.pollTimer);
      state.agent.pollTimer = null;
    }
  }

  function scheduleAgentPoll() {
    clearAgentPoll();
    if (
      state.route !== "home" ||
      !state.agent.selectedSessionID ||
      state.agent.newSessionMode ||
      document.hidden
    )
      return;
    const delay = window.__REPOPROMPT_PORTAL_TEST_HOOK__ ? 60_000 : 2_500;
    state.agent.pollTimer = window.setTimeout(async () => {
      state.agent.pollTimer = null;
      const latest = state.agent.transcriptItems.at(-1)?.sessionSequence || 0;
      await loadTranscript({ after: latest, silent: true });
    }, delay);
  }

  function renderAgentComposer() {
    const form = document.getElementById("composer-form");
    const options = document.getElementById("new-session-options");
    const providerSelect = document.getElementById("composer-provider");
    const modelSelect = document.getElementById("composer-model");
    const help = document.getElementById("composer-capability-help");
    const text = document.getElementById("composer-text");
    const submit = document.getElementById("composer-submit");
    options.hidden = !state.agent.newSessionMode;
    const providers = eligibleSessionProviders();
    const previousProvider = providerSelect.value;
    const previousModel = modelSelect.value;
    providerSelect.replaceChildren();
    providers.forEach((provider) => {
      const option = element("option", "", provider.displayName);
      option.value = provider.providerID;
      option.selected = provider.providerID === previousProvider;
      providerSelect.append(option);
    });
    const provider =
      providers.find((item) => item.providerID === providerSelect.value) ||
      providers[0];
    modelSelect.replaceChildren();
    const providerDefault = element("option", "", "Provider default");
    providerDefault.value = "";
    modelSelect.append(providerDefault);
    (provider?.models || []).forEach((model) => {
      const option = element("option", "", model.displayName);
      option.value = model.id;
      option.selected = previousModel
        ? model.id === previousModel
        : model.id === provider.preference?.defaultModel;
      modelSelect.append(option);
    });
    const modelReason = !provider
      ? "Connect and validate a CLI provider in Settings."
      : !provider.capabilities.supportsModelSelection
        ? "This provider uses its own default model."
        : !(provider.models || []).length
          ? "No sanitized model catalog is available for this account."
          : "Model choices come from the live provider catalog.";
    setDisabledReason(
      modelSelect,
      !provider?.capabilities.supportsModelSelection ||
        !(provider?.models || []).length,
      modelReason,
    );
    help.textContent = modelReason;
    const unavailable =
      state.agent.newSessionMode && (!selectedProject() || !provider);
    const empty = !text.value.trim();
    const reason = state.agent.mutationPromise
      ? "A message is already being sent."
      : !state.online
        ? "The server connection is unavailable."
        : unavailable
          ? "Select a project and connect a CLI provider first."
          : empty
            ? "Enter a message to send."
            : "";
    setDisabledReason(submit, Boolean(reason), reason);
    form.setAttribute(
      "aria-busy",
      String(Boolean(state.agent.mutationPromise)),
    );
    document.getElementById("composer-message").textContent =
      reason ||
      (state.agent.newSessionMode
        ? "Start a private root session."
        : "Send a follow-up to this session.");
    renderComposerContextUsage();
  }

  function renderComposerContextUsage() {
    const host = document.getElementById("composer-context-usage");
    const ring = document.getElementById("composer-context-usage-ring");
    const percentLabel = document.getElementById(
      "composer-context-usage-percent",
    );
    const progress = document.getElementById(
      "composer-context-usage-progress",
    );
    const session = selectedSession();
    const usage = session?.contextUsage || {};
    const last = Number(usage.lastTotalTokens) || 0;
    const total = Number(usage.totalTotalTokens) || 0;
    const used = last > 0 ? last : total;
    const windowTokens = effectiveContextWindowTokens(session, usage);
    const show =
      Boolean(session) &&
      !state.agent.newSessionMode &&
      (used > 0 || windowTokens > 0);
    host.hidden = !show;
    if (!show) {
      ring.removeAttribute("title");
      ring.removeAttribute("data-level");
      return;
    }
    const percent =
      used > 0 && windowTokens > 0
        ? Math.min(Math.max((used / windowTokens) * 100, 0), 100)
        : 0;
    const rounded = Math.round(percent);
    const circumference = 2 * Math.PI * 7;
    percentLabel.textContent = String(rounded);
    progress.setAttribute("stroke-dasharray", String(circumference));
    progress.setAttribute(
      "stroke-dashoffset",
      String(circumference * (1 - Math.min(Math.max(percent / 100, 0), 1))),
    );
    ring.dataset.level =
      percent > 90 ? "critical" : percent > 75 ? "warn" : "";
    ring.setAttribute("aria-valuenow", String(rounded));
    ring.title = contextUsageTooltip(used, windowTokens, percent);
  }

  function effectiveContextWindowTokens(session, usage) {
    const reported = Number(usage?.modelContextWindow) || 0;
    if (reported > 0) return reported;
    if (!session) return 0;
    return session.provider === "grokBuildACP" ? 500000 : 200000;
  }

  function contextUsageTooltip(used, windowTokens, percent) {
    if (used > 0 && windowTokens > 0) {
      return `Context used: ${Math.round(percent)}%\n${formatTokens(used)} / ${formatTokens(windowTokens)} tokens`;
    }
    if (used > 0) return `Used tokens: ${formatTokens(used)}`;
    return "Context usage unavailable";
  }

  function formatTokens(count) {
    if (count >= 1_000_000) return `${(count / 1_000_000).toFixed(1)}M`;
    if (count >= 1000) return `${(count / 1000).toFixed(1)}K`;
    return String(count);
  }

  function operationIDFor(payload) {
    const fingerprint = JSON.stringify(payload);
    if (state.agent.retryOperation?.fingerprint === fingerprint)
      return state.agent.retryOperation.operationID;
    if (!window.crypto?.randomUUID) return null;
    const operationID = window.crypto.randomUUID();
    state.agent.retryOperation = { fingerprint, operationID };
    return operationID;
  }

  async function submitComposer() {
    if (state.agent.mutationPromise) return state.agent.mutationPromise;
    const text = document.getElementById("composer-text").value.trim();
    if (!text) return null;
    const newSession = state.agent.newSessionMode;
    const payload = newSession
      ? {
          projectId: state.agent.selectedProjectID,
          providerId: document.getElementById("composer-provider").value,
          model: document.getElementById("composer-model").value || null,
          initialPrompt: text,
        }
      : {
          expectedRevision:
            state.agent.transcriptPage?.session?.revision ||
            selectedSession()?.revision,
          text,
        };
    const operationID = operationIDFor(payload);
    if (!operationID) {
      toast("This browser cannot create secure operation identifiers.", true);
      return null;
    }
    const body = { operationId: operationID, ...payload };
    state.agent.mutationPromise = (async () => {
      renderAgentComposer();
      try {
        if (newSession) {
          const session = await api("api/v1/sessions", {
            method: "POST",
            body: JSON.stringify(body),
          });
          state.bootstrap.sessions.push(session);
          state.agent.selectedSessionID = session.sessionId;
          state.agent.newSessionMode = false;
          state.agent.transcriptItems = [];
          state.agent.transcriptPage = null;
          state.agent.selectionGeneration += 1;
        } else {
          await api(
            `api/v1/sessions/${encodeURIComponent(state.agent.selectedSessionID)}/messages`,
            { method: "POST", body: JSON.stringify(body) },
          );
        }
        document.getElementById("composer-text").value = "";
        state.agent.retryOperation = null;
        renderHomeProviders();
        await loadTranscript({ silent: true });
        toast(newSession ? "Chat started" : "Message accepted");
      } catch (error) {
        const composerMessage = document.getElementById("composer-message");
        composerMessage.textContent =
          error.code === "staleRevision"
            ? "Session changed; review your message and send again."
            : error.message;
        toast(error.message, true);
        if (error.code === "staleRevision")
          await loadTranscript({ silent: true });
      } finally {
        state.agent.mutationPromise = null;
        renderAgentComposer();
      }
    })();
    return state.agent.mutationPromise;
  }

  function renderHomeError(error) {
    const panel = element("div", "error-banner");
    panel.setAttribute("role", "alert");
    panel.append(iconNode("warning"), document.createTextNode(error.message));
    document.getElementById("session-list").replaceChildren(panel);
    document
      .getElementById("transcript-list")
      .replaceChildren(panel.cloneNode(true));
    installIcons(document.getElementById("home-shell"));
  }

  function normalizedRoute() {
    const raw = location.hash.replace(/^#/, "");
    if (!raw || raw === "home") return { surface: "home", page: null };
    if (raw === "settings") return { surface: "settings", page: "overview" };
    if (raw.startsWith("settings/")) {
      const page = raw.slice("settings/".length);
      return {
        surface: "settings",
        page: supportedRoutes.has(page) ? page : "overview",
      };
    }
    return { surface: "home", page: null };
  }

  function disposeSensitiveInputs(root = document) {
    root.querySelectorAll("input[data-sensitive]").forEach((input) => {
      input.value = "";
      input.removeAttribute("value");
    });
  }

  function renderRoute() {
    const route = normalizedRoute();
    state.route = route.surface === "home" ? "home" : `settings/${route.page}`;
    const home = document.getElementById("home-shell");
    const settings = document.getElementById("settings-shell");
    home.hidden = route.surface !== "home";
    settings.hidden = route.surface !== "settings";
    document.getElementById("window-title-text").textContent =
      route.surface === "home" ? "Agent Mode" : "Settings";
    if (route.surface === "home") {
      renderHomeProviders();
      if (state.agent.selectedSessionID && !state.agent.transcriptPage) {
        loadTranscript();
      } else {
        scheduleAgentPoll();
      }
    } else {
      clearAgentPoll();
    }
    document.querySelectorAll("#settings-nav a[data-route]").forEach((link) => {
      const active =
        route.surface === "settings" && link.dataset.route === route.page;
      link.classList.toggle("active", active);
      if (active) link.setAttribute("aria-current", "page");
      else link.removeAttribute("aria-current");
    });

    if (route.surface === "settings") {
      const titles = {
        overview: "Overview",
        "cli-providers": "CLI Providers",
        "agent-models": "Agent Models",
        "agent-permissions": "Agent Permissions",
        "agent-workflows": "Agent Workflows",
        "context-builder": "Context Builder",
        "portal-appearance": "Portal Appearance",
        advanced: "Advanced",
        "mcp-server": "MCP Server",
        "mcp-tools": "Tools",
        "workspace-approvals": "Workspace Approvals",
        "model-presets": "Model Presets",
        "api-providers": "API Providers",
        openrouter: "OpenRouter",
        "custom-api": "Custom API",
        "model-config": "Model Config",
        "manage-workspaces": "Manage Workspaces",
        "manage-presets": "Manage Presets",
      };
      document.getElementById("settings-detail-title").textContent =
        titles[route.page];
      const renderers = {
        overview: renderOverview,
        "cli-providers": renderCLIProviders,
        "agent-models": renderTypedAgentModels,
        "agent-permissions": renderAgentPermissions,
        "agent-workflows": renderTypedAgentWorkflows,
        "context-builder": renderTypedContextBuilder,
        "portal-appearance": renderPortalAppearance,
        advanced: renderAdvanced,
        "mcp-server": renderMCPServer,
        "mcp-tools": renderMCPTools,
        "workspace-approvals": renderWorkspaceApprovals,
        "model-presets": renderTypedModelPresets,
        "api-providers": renderTypedAPIProviders,
        openrouter: renderTypedOpenRouter,
        "custom-api": renderTypedCustomAPI,
        "model-config": renderModelConfig,
        "manage-workspaces": renderManageWorkspaces,
        "manage-presets": renderTypedManagePresets,
      };
      if ((!state.providers.length || !state.desktopSettings) && state.loading)
        renderInitialSettingsLoading();
      else renderers[route.page]();
    }

    if (state.focusAfterRoute) {
      state.focusAfterRoute = false;
      window.setTimeout(() => {
        (route.surface === "settings"
          ? document.getElementById("settings-main-content")
          : document.getElementById("main-content")
        ).focus({
          preventScroll: true,
        });
      }, 0);
    }
  }

  function renderInitialSettingsLoading() {
    const content = document.getElementById("settings-content");
    disposeSensitiveInputs(content);
    const panel = element("div", "empty-state-panel");
    panel.append(
      element("h2", "", "Loading settings"),
      element("p", "", "Reading the provider catalog and server readiness."),
    );
    content.replaceChildren(panel);
  }

  function pageHeader(title, subtitle, icon) {
    const header = element("header", "settings-header");
    const titleRow = element("div", "settings-header-icon");
    if (icon) titleRow.append(iconNode(icon));
    titleRow.append(element("h1", "", title));
    header.append(titleRow, element("p", "", subtitle));
    return header;
  }

  function recommendation(icon, title, detail, action = null) {
    const banner = element("div", "recommendation-banner");
    banner.append(iconNode(icon));
    const copy = element("div", "recommendation-copy");
    copy.append(
      element("strong", "", title),
      document.createElement("br"),
      document.createTextNode(detail),
    );
    banner.append(copy);
    if (action) {
      const button = element(
        "button",
        "secondary-button recommendation-action",
        action.label,
      );
      button.type = "button";
      button.dataset.action = action.id || "recommendation-action";
      button.addEventListener("click", action.handler);
      banner.append(button);
    }
    return banner;
  }

  function isConnectedProvider(provider) {
    return Boolean(
      provider?.authentication?.authenticated &&
        provider?.connection?.state === "connected" &&
        provider?.connection?.testState === "valid",
    );
  }

  function navigateToSettings(page) {
    state.focusAfterRoute = true;
    window.location.hash = `#settings/${page}`;
  }

  function settingValue(key, fallback = "") {
    return state.desktopSettings?.values?.[key] ?? fallback;
  }

  function settingBool(key, fallback = false) {
    const value = settingValue(key, fallback ? "true" : "false");
    return value === "true";
  }

  function settingArray(key) {
    try {
      const value = JSON.parse(settingValue(key, "[]"));
      return Array.isArray(value) ? value : [];
    } catch (_error) {
      return [];
    }
  }

  async function saveSetting(key, value, control) {
    return saveSettingsChanges({ [key]: String(value) }, control);
  }

  async function saveSettingsChanges(changes, control) {
    if (!state.desktopSettings || state.settingsMutation) return;
    state.settingsMutation = (async () => {
      if (control) setDisabledReason(control, true, "Saving setting…");
      try {
        state.desktopSettings = await api("api/v1/desktop-settings", {
          method: "PATCH",
          body: JSON.stringify({
            expectedRevision: state.desktopSettings.revision,
            changes,
          }),
        });
        renderRoute();
      } catch (error) {
        toast(error.message, true);
        if (error.code === "staleRevision") await loadAll(false);
        else renderRoute();
      } finally {
        state.settingsMutation = null;
      }
    })();
    return state.settingsMutation;
  }

  function desktopCard(title, detail) {
    const card = element("section", "desktop-settings-card");
    if (title) card.append(element("h2", "", title));
    if (detail) card.append(element("p", "card-subtitle", detail));
    return card;
  }

  function desktopRow(label, detail, control) {
    const row = element("div", "desktop-setting-row");
    const copy = element("div", "desktop-setting-copy");
    copy.append(element("strong", "", label));
    if (detail) copy.append(element("small", "", detail));
    row.append(copy, control);
    return row;
  }

  function toggleSetting(key, label, detail, fallback = false) {
    const toggle = element("label", "toggle desktop-toggle");
    const input = document.createElement("input");
    input.type = "checkbox";
    input.checked = settingBool(key, fallback);
    input.setAttribute("aria-label", label);
    input.addEventListener("change", () =>
      saveSetting(key, input.checked, input),
    );
    toggle.append(input, element("span"));
    return desktopRow(label, detail, toggle);
  }

  function selectSetting(key, label, detail, options, fallback = "") {
    const select = document.createElement("select");
    select.setAttribute("aria-label", label);
    options.forEach(([value, title]) => {
      const option = element("option", "", title);
      option.value = value;
      option.selected = value === settingValue(key, fallback);
      select.append(option);
    });
    select.addEventListener("change", () =>
      saveSetting(key, select.value, select),
    );
    return desktopRow(label, detail, select);
  }

  function textSetting(key, label, detail, placeholder = "") {
    const input = document.createElement("input");
    input.type = "text";
    input.value = settingValue(key);
    input.placeholder = placeholder;
    input.setAttribute("aria-label", label);
    input.addEventListener("change", () =>
      saveSetting(key, input.value.trim(), input),
    );
    return desktopRow(label, detail, input);
  }

  function numberSetting(key, label, detail, min, max, step = 1) {
    const input = document.createElement("input");
    input.type = "number";
    input.min = String(min);
    input.max = String(max);
    input.step = String(step);
    input.value = settingValue(key);
    input.setAttribute("aria-label", label);
    input.addEventListener("change", () =>
      saveSetting(key, input.value, input),
    );
    return desktopRow(label, detail, input);
  }

  function modelChoices(includeAutomatic = true) {
    const choices = [];
    if (includeAutomatic) choices.push(["", "Automatic"]);
    const seen = new Set();
    orderedProviders().forEach((provider) =>
      (provider.models || []).forEach((model) => {
        if (seen.has(model.id)) return;
        seen.add(model.id);
        choices.push([
          model.id,
          `${model.displayName} · ${provider.displayName}`,
        ]);
      }),
    );
    return choices;
  }

  function informationalCard(title, detail, rows = []) {
    const card = desktopCard(title, detail);
    rows.forEach(([label, value, rowDetail = ""]) =>
      card.append(
        desktopRow(label, rowDetail, element("span", "read-only-value", value)),
      ),
    );
    return card;
  }

  function settingsPage(title, subtitle, icon, cards = [], banner = null) {
    const content = document.getElementById("settings-content");
    disposeSensitiveInputs(content);
    content.replaceChildren(pageHeader(title, subtitle, icon));
    if (banner) content.append(banner);
    cards.forEach((card) => content.append(card));
    installIcons(content);
  }

  function renderCLIProviders() {
    const content = document.getElementById("settings-content");
    disposeSensitiveInputs(content);
    content.replaceChildren(
      pageHeader(
        "CLI Providers",
        "Primary way to add Agent Mode model support. Connect Claude Code, Codex, OpenCode, Cursor, or Grok Build to use the dedicated server account for each installed CLI.",
        "terminal",
      ),
    );
    const byID = Object.fromEntries(
      orderedProviders().map((provider) => [provider.providerID, provider]),
    );
    const connectedMainProviders = [
      byID.codex,
      byID.claudeCompatible,
      byID.openCodeACP,
      byID.cursorACP,
      byID.grokBuildACP,
    ].filter(isConnectedProvider);
    if (connectedMainProviders.length) {
      content.append(
        recommendation(
          "check",
          "CLI providers connected.",
          "Check recommendations to optimize your setup.",
          {
            label: "Check Now",
            id: "check-agent-model-recommendations",
            handler: () => navigateToSettings("agent-models"),
          },
        ),
      );
    }
    const stack = element("div", "desktop-provider-list");
    if (byID.codex) stack.append(cliProviderCard(byID.codex));
    if (byID.claudeCompatible)
      stack.append(cliProviderCard(byID.claudeCompatible));
    stack.append(
      compatibleBackendsCard(
        [byID.claudeGLM, byID.claudeKimi, byID.claudeCustom].filter(Boolean),
      ),
    );
    if (byID.openCodeACP) stack.append(cliProviderCard(byID.openCodeACP));
    if (byID.cursorACP) stack.append(cliProviderCard(byID.cursorACP));
    if (byID.grokBuildACP) stack.append(cliProviderCard(byID.grokBuildACP));
    content.append(stack);
    installIcons(content);
  }

  const externalCLIAuthenticationMethods = {
    claudeCompatible: "providerSpecific",
    openCodeACP: "providerSpecific",
    cursorACP: "browserLogin",
    grokBuildACP: "providerSpecific",
  };

  function cliProviderCard(provider) {
    const presentation = desktopProviderPresentation(provider);
    const details = element("details", "desktop-provider-card");
    details.dataset.providerId = provider.providerID;
    const summary = document.createElement("summary");
    const status = providerStatus(provider);
    const badge = element("span", `connection-badge ${status.tone}`.trim());
    badge.append(element("i"), element("span", "", status.label));
    const name = element("span", "provider-name");
    name.append(
      element("strong", "", presentation.title),
      element("small", "", presentation.subtitle),
    );
    summary.append(
      iconNode("terminal", "provider-glyph"),
      name,
      badge,
      iconNode("chevron"),
    );
    const body = element("div", "desktop-provider-body");
    const compatibleBackend = [
      "claudeGLM",
      "claudeKimi",
      "claudeCustom",
    ].includes(provider.providerID);
    const connected = isConnectedProvider(provider);

    if (compatibleBackend) {
      body.append(compatibleBackendPrerequisite(provider));
      const directMethods = (
        provider.capabilities.authenticationMethods || []
      ).filter((method) => directAuthenticationMethods.has(method));
      if (directMethods.length) {
        const labels = {
          claudeGLM: [
            "Z.ai API Key",
            "Save the key for the Z.ai coding-plan backend. The same Claude CLI binary runs this route; a Claude account login is not required.",
          ],
          claudeKimi: [
            "Kimi API Key",
            "Save the key for Kimi's coding backend. Model behavior and slot mappings live in the backend settings below.",
          ],
        };
        body.append(
          credentialForm(provider, directMethods, {
            title: labels[provider.providerID]?.[0],
            subtitle: labels[provider.providerID]?.[1],
          }),
        );
      }
      body.append(compatibleBackendSettingsCard(provider));
      if (connected) body.append(connectedProviderSummary(provider));
      else if (!directMethods.length)
        body.append(
          element(
            "p",
            "unavailable-panel",
            providerActionUnavailableReason(provider),
          ),
        );
      details.append(summary, body);
      return details;
    }

    if (connected) {
      body.append(connectedProviderSummary(provider));
      body.append(providerRuntimeControls(provider));
    } else if (provider.providerID === "codex") {
      const note = element("p", "codex-auth-note");
      note.append(
        document.createTextNode(
          "ChatGPT may require identity verification (KYC) to access Codex. ",
        ),
      );
      const link = element("a", "", "Learn more");
      link.href = "https://chatgpt.com/cyber";
      link.target = "_blank";
      link.rel = "noopener noreferrer";
      note.append(link);
      body.append(
        note,
        element(
          "p",
          "card-subtitle",
          "Permissions and runtime controls appear here after Codex is connected.",
        ),
      );
      const methods = provider.capabilities.authenticationMethods || [];
      if (methods.length) {
        const message = element(
          "div",
          "inline-message info",
          "Choose a sign-in method to connect Codex.",
        );
        message.setAttribute("role", "status");
        body.append(authenticationMethodChoices(provider, message));
        if (state.activeFlow?.providerID === provider.providerID)
          body.append(devicePanel(provider));
        const directMethods = methods.filter((method) =>
          directAuthenticationMethods.has(method),
        );
        if (directMethods.length)
          body.append(credentialForm(provider, directMethods));
        body.append(message);
      } else {
        body.append(
          element(
            "p",
            "unavailable-panel",
            providerActionUnavailableReason(provider),
          ),
        );
      }
    } else if (externalCLIAuthenticationMethods[provider.providerID]) {
      body.append(externalCLIConnectPanel(provider));
      if (provider.providerID === "claudeCompatible")
        body.append(providerRuntimeControls(provider));
    } else {
      body.append(
        element(
          "p",
          "unavailable-panel",
          providerActionUnavailableReason(provider),
        ),
      );
    }
    details.append(summary, body);
    return details;
  }

  function externalCLIConnectPanel(provider) {
    const method = externalCLIAuthenticationMethods[provider.providerID];
    const methods = provider.capabilities.authenticationMethods || [];
    const guidance = {
      claudeCompatible: [
        "Connect the dedicated Claude Code CLI account mounted for this server.",
        "If the account is not signed in, an operator can run claude login inside the isolated server account. Compatible backends below use their own API keys and do not require this login.",
      ],
      openCodeACP: [
        "Connect the dedicated OpenCode CLI account mounted for this server.",
        "If authentication is missing, an operator can run opencode auth login inside the isolated server account.",
      ],
      cursorACP: [
        "Connect the dedicated Cursor CLI account mounted for this server.",
        "If authentication is missing, an operator can complete Cursor login inside the isolated server account.",
      ],
      grokBuildACP: [
        "Connect the dedicated Grok Build CLI account mounted for this server.",
        "If authentication is missing, an operator can complete Grok Build login inside the isolated server account.",
      ],
    }[provider.providerID];
    const card = desktopCard("Connection", guidance[0]);
    card.append(
      element("p", "card-subtitle external-login-guidance", guidance[1]),
    );
    const message = element(
      "div",
      "inline-message info",
      "The portal records use of the mounted CLI account; it never receives or copies the provider's login files.",
    );
    message.setAttribute("role", "status");
    const actions = element("div", "form-actions");
    const button = element("button", "primary-button", "Connect");
    button.type = "button";
    button.dataset.action = "connect-external-cli-provider";
    const available =
      provider.deploymentAllowed &&
      provider.cli?.installed !== false &&
      methods.includes(method);
    if (!available)
      setDisabledReason(
        button,
        true,
        providerActionUnavailableReason(provider),
      );
    else
      button.addEventListener("click", () =>
        connectExternalCLIProvider(provider, method, button, message),
      );
    actions.append(
      element("span", "form-note", "No credential fields are sent."),
      button,
    );
    card.append(actions, message);
    return card;
  }

  async function connectExternalCLIProvider(provider, method, button, message) {
    const originalLabel = button.textContent;
    button.textContent = "Connecting…";
    setDisabledReason(button, true, "Connection request is in progress.");
    message.textContent = "Checking the mounted CLI account…";
    try {
      const updated = await api(
        `api/v1/provider-settings/${encodeURIComponent(provider.providerID)}/connect`,
        {
          method: "POST",
          body: JSON.stringify({ authenticationMethod: method }),
        },
      );
      replaceProvider(updated);
      renderHomeProviders();
      renderRoute();
      toast(`${provider.displayName} connected`);
      announce(`${provider.displayName} connected`);
    } catch (error) {
      message.textContent = error.message;
      message.className = "inline-message error";
      message.focus({ preventScroll: true });
      button.textContent = originalLabel;
      setDisabledReason(button, false, "");
      toast(error.message, true);
    }
  }

  function providerActionUnavailableReason(provider) {
    if (!provider.deploymentAllowed)
      return "This packaged provider is not enabled for this server deployment.";
    if (provider.cli?.installed === false)
      return "The provider command is not installed on this server.";
    if (provider.providerID === "claudeCustom")
      return "Custom endpoint credentials remain an operator-managed boundary because this Claude-compatible backend does not advertise a safe endpoint validator.";
    if (
      ["claudeCompatible", "openCodeACP", "cursorACP"].includes(
        provider.providerID,
      )
    )
      return "The dedicated CLI credential directory is not mounted or is unavailable. Complete sign-in in the isolated server account, then refresh.";
    return "No connection method is available for this provider on the server.";
  }

  function connectedProviderSummary(provider) {
    const external = ["providerSpecific", "browserLogin"].includes(
      provider.connection?.authenticationMethod,
    );
    const compatibleBackend = [
      "claudeGLM",
      "claudeKimi",
      "claudeCustom",
    ].includes(provider.providerID);
    const card = desktopCard(
      provider.providerID === "codex" ? "Signed in to Codex" : "Connected",
    );
    const summary = provider.authentication || {};
    const rows = element("dl", "desktop-account-summary");
    const account =
      summary.accountLabel ||
      provider.connection?.accountLabel ||
      (external ? "Dedicated server CLI account" : "Connected account");
    rows.append(element("dt", "", "Account"), element("dd", "", account));
    if (provider.providerID === "codex" || summary.planLabel)
      rows.append(
        element("dt", "", "Plan"),
        element("dd", "", summary.planLabel || "Plan not provided"),
      );
    rows.append(
      element("dt", "", "Authentication"),
      element(
        "dd",
        "",
        summary.authenticationLabel ||
          (external
            ? "Mounted CLI login"
            : humanize(
                summary.method || provider.connection?.authenticationMethod,
              )),
      ),
    );
    const actions = element("div", "button-row desktop-connection-actions");
    const message = element(
      "div",
      "inline-message info",
      external
        ? provider.connection?.detail ||
            "The dedicated CLI account passed server validation."
        : "Connection is ready.",
    );
    const test = element("button", "secondary-button", "Test Connection");
    test.type = "button";
    test.dataset.action = "test-connection";
    test.addEventListener("click", () =>
      runConnectionAction(provider, "test", test, message),
    );
    const removalLabel = external
      ? "Disconnect"
      : compatibleBackend
        ? "Delete Key"
        : "Sign Out";
    const remove = element("button", "danger-button subtle", removalLabel);
    remove.type = "button";
    remove.dataset.action = "request-disconnect";
    remove.addEventListener("click", async () => {
      const accepted = await confirmAction({
        title: `${removalLabel} ${provider.displayName}?`,
        message: external
          ? "New agent runs will stop using this mounted account. The operator-managed CLI login files are not modified."
          : "The stored connection will be removed and new agent runs will no longer use it.",
        label: removalLabel,
        returnFocus: remove,
      });
      if (accepted)
        await runConnectionAction(provider, "disconnect", remove, message);
    });
    actions.append(test, remove);
    card.append(rows, actions, message);
    return card;
  }

  function providerRuntimeControls(provider, title = "Permissions & Runtime") {
    const card = desktopCard(
      title,
      "Permission Level is edited on Agent Permissions. These leftover tool flags still apply at launch.",
    );
    if (provider.providerID === "codex") {
      card.append(
        element("h3", "desktop-subheading", "Core tools"),
        toggleSetting(
          "codexSearchEnabled",
          "Search",
          "Allow live web search requests from Codex.",
          true,
        ),
        toggleSetting(
          "codexGoalsEnabled",
          "Goals",
          "Enable /goal support and the goal lifecycle for Codex Agent Mode.",
          true,
        ),
        toggleSetting(
          "codexReasoningSummariesEnabled",
          "Reasoning Summaries",
          "Request model reasoning summaries for app-server threads.",
          false,
        ),
        toggleSetting(
          "codexMemoriesEnabled",
          "Local Memories",
          "Allow Codex to generate and use memories in its isolated server home.",
          false,
        ),
      );
      const mcp = desktopRow(
        "MCP servers",
        "RepoPrompt is required for Agent Mode.",
        element("span", "required-pill", "RepoPrompt · Required"),
      );
      card.append(mcp);
    } else if (provider.providerID === "claudeCompatible") {
      card.append(
        element("h3", "desktop-subheading", "Tools"),
        toggleSetting(
          "claudeToolSearchEnabled",
          "Lazy Tool Loading",
          "Claude searches for each tool before use; this saves context but adds latency.",
          true,
        ),
        promptDeliveryPicker(),
      );
    } else {
      card.append(
        desktopRow(
          provider.providerID === "cursorACP"
            ? "ACP Auto-Approve"
            : "ACP Session Mode",
          "Typed Direct Agents settings are the permission authority.",
          element("span", "read-only-value", liveManagedPermissionLabel(provider.providerID)),
        ),
      );
    }
    return card;
  }

  function compatibleBackendPrerequisite(provider) {
    const installed = provider.cli?.installed !== false;
    const panel = element(
      "div",
      installed ? "inline-message success" : "inline-message warning",
    );
    panel.append(
      iconNode(installed ? "check" : "warning"),
      document.createTextNode(
        installed
          ? "Claude CLI is installed. This backend uses its own API key; a Claude account login is not required."
          : "Claude CLI is missing. Install the packaged Claude Code CLI before testing this backend.",
      ),
    );
    return panel;
  }

  function compatibleBackendsCard(providers) {
    const details = element(
      "details",
      "desktop-provider-card compatible-provider-card",
    );
    const summary = document.createElement("summary");
    const name = element("span", "provider-name");
    name.append(
      element("strong", "", "Claude Code–Compatible Backends"),
      element(
        "small",
        "",
        "Use Claude Code with GLM (Z.AI), Kimi (Moonshot AI), or a custom compatible endpoint.",
      ),
    );
    const badge = element("span", "connection-badge");
    badge.append(
      element("i"),
      element(
        "span",
        "",
        providers.some((provider) => provider.authentication?.authenticated)
          ? "Connected"
          : "Not configured",
      ),
    );
    summary.append(
      iconNode("terminal", "provider-glyph"),
      name,
      badge,
      iconNode("chevron"),
    );
    const body = element("div", "compatible-backend-list");
    providers.forEach((provider) => body.append(cliProviderCard(provider)));
    if (!providers.length)
      body.append(
        element(
          "p",
          "unavailable-panel",
          "Compatible backend settings are not present in the server catalog.",
        ),
      );
    details.append(summary, body);
    return details;
  }

  function compatibleBackendSettingsCard(provider) {
    const definitions = {
      claudeGLM: {
        keys: {
          displayName: "claudeGLMDisplayName",
          baseURL: "claudeGLMBaseURL",
          auth: "claudeGLMAuthHeader",
          haiku: "claudeGLMHaikuModel",
          sonnet: "claudeGLMSonnetModel",
          opus: "claudeGLMOpusModel",
        },
        behavior: "claudeSlotMapping",
      },
      claudeKimi: {
        keys: {
          displayName: "claudeKimiDisplayName",
          baseURL: "claudeKimiBaseURL",
          auth: "claudeKimiAuthHeader",
          behavior: "claudeKimiModelBehavior",
          haiku: "claudeKimiHaikuModel",
          sonnet: "claudeKimiSonnetModel",
          opus: "claudeKimiOpusModel",
        },
        behavior: settingValue("claudeKimiModelBehavior", "noModel"),
      },
      claudeCustom: {
        keys: {
          displayName: "claudeCustomDisplayName",
          baseURL: "claudeCustomBaseURL",
          auth: "claudeCustomAuthHeader",
          behavior: "claudeCustomModelBehavior",
          haiku: "claudeCustomHaikuModel",
          sonnet: "claudeCustomSonnetModel",
          opus: "claudeCustomOpusModel",
        },
        behavior: settingValue("claudeCustomModelBehavior", "noModel"),
      },
    };
    const definition = definitions[provider.providerID];
    const custom = provider.providerID === "claudeCustom";
    const card = desktopCard(
      custom ? "Custom Backend" : "Backend Behavior",
      custom
        ? "Define an Anthropic-compatible endpoint. Credential entry is unavailable because this backend does not advertise a safe configured-host validator."
        : "These runtime settings mirror the desktop backend behavior. Provider credentials are managed in the key section above.",
    );
    if (custom) {
      card.append(
        toggleSetting(
          "claudeCustomEnabled",
          "Available for new sessions",
          "Same persist flag launch resolution reads. Default off.",
          false,
        ),
      );
    } else {
      card.append(
        desktopRow(
          "Available for new sessions",
          "Enable this backend in the server provider catalog.",
          providerEnabledToggle(provider),
        ),
      );
    }

    const form = element("form", "compatible-backend-form");
    const primaryFields = element("div", "settings-form");
    const advancedFields = element("div", "settings-form");
    function field(container, name, label, type = "text") {
      const key = definition.keys[name];
      const wrapper = element("label", "field");
      wrapper.append(element("span", "", label));
      const input = document.createElement(
        type === "select" ? "select" : "input",
      );
      input.name = name;
      input.dataset.settingKey = key;
      if (type !== "select") {
        input.type = type;
        input.value = settingValue(key);
      }
      wrapper.append(input);
      container.append(wrapper);
      return input;
    }

    function addAuthField(container) {
      const auth = field(container, "auth", "Auth header", "select");
      [
        ["anthropicAPIKey", "ANTHROPIC_API_KEY"],
        ["anthropicAuthToken", "ANTHROPIC_AUTH_TOKEN"],
      ].forEach(([value, label]) => {
        const option = element("option", "", label);
        option.value = value;
        option.selected = value === settingValue(definition.keys.auth);
        auth.append(option);
      });
    }

    let behavior = definition.behavior;
    let behaviorSelect = null;
    if (custom) {
      field(primaryFields, "displayName", "Display name");
      field(primaryFields, "baseURL", "Base URL", "url");
      addAuthField(primaryFields);
    }
    if (definition.keys.behavior) {
      behaviorSelect = field(
        primaryFields,
        "behavior",
        "Model behavior",
        "select",
      );
      [
        ["noModel", "No model flag"],
        ["claudeSlotMapping", "Claude slot mappings"],
      ].forEach(([value, label]) => {
        const option = element("option", "", label);
        option.value = value;
        option.selected = value === behavior;
        behaviorSelect.append(option);
      });
    }

    const slots = element("fieldset", "compatible-slot-fields");
    slots.append(element("legend", "", "Claude slot → backend model ID"));
    if (definition.keys.haiku) {
      [
        ["haiku", "Haiku"],
        ["sonnet", "Sonnet"],
        ["opus", "Opus"],
      ].forEach(([name, label]) => {
        const wrapper = element("label", "field");
        wrapper.append(element("span", "", label));
        const input = document.createElement("input");
        input.name = name;
        input.dataset.settingKey = definition.keys[name];
        input.value = settingValue(definition.keys[name]);
        wrapper.append(input);
        slots.append(wrapper);
      });
      slots.hidden = behavior !== "claudeSlotMapping";
      primaryFields.append(slots);
    }
    if (behaviorSelect)
      behaviorSelect.addEventListener("change", () => {
        behavior = behaviorSelect.value;
        slots.hidden = behavior !== "claudeSlotMapping";
      });

    if (!custom) {
      field(advancedFields, "displayName", "Display name");
      field(advancedFields, "baseURL", "Base URL", "url");
      addAuthField(advancedFields);
      const advanced = element("details", "compatible-advanced");
      advanced.append(
        element("summary", "", "Advanced"),
        element(
          "p",
          "card-subtitle",
          "Override the desktop preset's display name, fixed compatible base URL, or authentication header.",
        ),
        advancedFields,
      );
      form.append(primaryFields, advanced);
    } else {
      form.append(primaryFields);
    }

    const message = element(
      "div",
      "inline-message info",
      "Secrets are stored separately and never appear in these settings.",
    );
    message.setAttribute("role", "status");
    const actions = element("div", "form-actions");
    const save = element("button", "primary-button", "Save Settings");
    save.type = "submit";
    save.dataset.action = "save-compatible-backend-settings";
    actions.append(
      element("span", "form-note", "Applies to new sessions."),
      save,
    );
    form.append(message, actions);
    form.addEventListener("submit", async (event) => {
      event.preventDefault();
      const changes = {};
      form.querySelectorAll("[data-setting-key]").forEach((input) => {
        changes[input.dataset.settingKey] = input.value.trim();
      });
      await saveSettingsChanges(changes, save);
      await loadAll(true);
    });
    card.append(form);
    return card;
  }

  function providerEnabledToggle(provider) {
    const toggle = element("label", "toggle desktop-toggle");
    const input = document.createElement("input");
    input.type = "checkbox";
    input.checked = provider.preference.enabled;
    input.setAttribute("aria-label", `Enable ${provider.displayName}`);
    if (!provider.deploymentAllowed)
      setDisabledReason(
        input,
        true,
        "This provider is not enabled for the server deployment.",
      );
    input.addEventListener("change", async () => {
      setDisabledReason(input, true, "Saving provider state…");
      try {
        const updated = await api(
          `api/v1/provider-settings/${encodeURIComponent(provider.providerID)}/${input.checked ? "enable" : "disable"}`,
          {
            method: "POST",
            body: JSON.stringify({
              expectedRevision: provider.preference.revision,
            }),
          },
        );
        replaceProvider(updated);
        renderRoute();
        announce(
          `${provider.displayName} ${input.checked ? "enabled" : "disabled"}`,
        );
      } catch (error) {
        input.checked = !input.checked;
        setDisabledReason(input, false, "");
        toast(error.message, true);
      }
    });
    toggle.append(input, element("span"));
    return toggle;
  }

  function typedSelect(label, options, currentValue) {
    const select = document.createElement("select");
    select.setAttribute("aria-label", label);
    options.forEach(([value, title]) => {
      const option = element("option", "", title);
      option.value = value;
      option.selected = value === currentValue;
      select.append(option);
    });
    return select;
  }

  function typedToggle(label, checked) {
    const toggle = element("label", "toggle desktop-toggle");
    const input = document.createElement("input");
    input.type = "checkbox";
    input.checked = checked;
    input.setAttribute("aria-label", label);
    toggle.append(input, element("span"));
    return { toggle, input };
  }

  function promptDeliveryChoices() {
    return [
      ["nativeSystemPrompt", "Replace System Prompt"],
      [
        "userMessageXMLWithEmptySystemPrompt",
        "User Message (No Native)",
      ],
      ["userMessageXML", "User Message (Keep Native)"],
    ];
  }

  function livePromptDelivery() {
    return (
      state.typedSettings.directAgentPermissions?.settings?.claude
        ?.promptDelivery || "nativeSystemPrompt"
    );
  }

  function promptDeliveryPicker() {
    const select = typedSelect(
      "Sys Prompt Packaging",
      promptDeliveryChoices(),
      livePromptDelivery(),
    );
    select.addEventListener("change", () => savePromptDelivery(select));
    return desktopRow(
      "Sys Prompt Packaging",
      "Replace Claude Code's native system prompt, wrap RepoPrompt instructions in the user message, or keep the native prompt. Writes the typed Direct Agents store.",
      select,
    );
  }

  async function savePromptDelivery(select) {
    const snapshot = state.typedSettings.directAgentPermissions;
    if (!snapshot) return;
    const settings = snapshot.settings;
    return mutateDomain(
      "directAgentPermissions",
      select,
      () =>
        api("api/v1/settings/direct-agent-permissions", {
          method: "PATCH",
          body: JSON.stringify({
            expectedRevision: snapshot.revision,
            settings: {
              ...settings,
              claude: {
                ...settings.claude,
                promptDelivery: select.value,
              },
            },
          }),
        }),
      (value) => {
        state.typedSettings.directAgentPermissions = value;
      },
    );
  }

  const workspaceApprovalOperations = [
    ["create_workspace", "Create Workspace", "Create a desktop workspace."],
    ["delete_workspace", "Delete Workspace", "Delete a desktop workspace."],
    ["add_folder", "Add Folder", "Attach a folder to a desktop workspace."],
    [
      "remove_folder",
      "Remove Folder",
      "Detach a folder from a desktop workspace.",
    ],
  ];

  function cloneWorkspaceApprovalSettings(snapshot) {
    return {
      autoApproveAll: !!snapshot.settings?.autoApproveAll,
      autoApproveOperations: [
        ...(snapshot.settings?.autoApproveOperations || []),
      ],
      clientPolicies: JSON.parse(
        JSON.stringify(snapshot.settings?.clientPolicies || {}),
      ),
    };
  }

  function saveWorkspaceApprovals(snapshot, mutateSettings, control) {
    const settings = cloneWorkspaceApprovalSettings(snapshot);
    mutateSettings(settings);
    return mutateDomain(
      "workspaceApprovals",
      control,
      () =>
        api("api/v1/settings/workspace-approvals", {
          method: "PATCH",
          body: JSON.stringify({
            expectedRevision: snapshot.revision,
            settings,
          }),
        }),
      (value) => {
        state.typedSettings.workspaceApprovals = value;
      },
    );
  }

  function saveMCPDisabledTools(snapshot, disabledTools, control) {
    return mutateDomain(
      "mcpDisabledTools",
      control,
      () =>
        api("api/v1/settings/mcp-disabled-tools", {
          method: "PATCH",
          body: JSON.stringify({
            expectedRevision: snapshot.revision,
            settings: { disabledTools: [...disabledTools] },
          }),
        }),
      (value) => {
        state.typedSettings.mcpDisabledTools = value;
      },
    );
  }

  function saveShowModelPresets(snapshot, enabled, control) {
    return mutateDomain(
      "showModelPresets",
      control,
      () =>
        api("api/v1/settings/show-model-presets", {
          method: "PATCH",
          body: JSON.stringify({
            expectedRevision: snapshot.revision,
            settings: { showModelPresets: enabled },
          }),
        }),
      (value) => {
        state.typedSettings.showModelPresets = value;
      },
    );
  }

  function agentTargetValue(target) {
    if (!target) return "";
    return [
      target.providerID,
      target.modelID || "",
      target.reasoningEffort || "",
    ]
      .map(encodeURIComponent)
      .join("|");
  }

  function agentTargetFromValue(value, pinned = false) {
    if (!value) return null;
    const [providerID, modelID, reasoningEffort] = value
      .split("|")
      .map(decodeURIComponent);
    return {
      providerID,
      modelID: modelID || null,
      reasoningEffort: reasoningEffort || null,
      pinned,
    };
  }

  function agentTargetChoices() {
    const choices = [["", "Unassigned"]];
    orderedProviders()
      .filter((provider) => provider.deploymentAllowed)
      .forEach((provider) => {
        if (!(provider.models || []).length) {
          const target = { providerID: provider.providerID };
          choices.push([
            agentTargetValue(target),
            `${provider.displayName} · Provider default`,
          ]);
        }
        (provider.models || []).forEach((modelEntry) => {
          const efforts = modelEntry.reasoningEfforts?.length
            ? modelEntry.reasoningEfforts
            : [null];
          efforts.forEach((effort) => {
            const target = {
              providerID: provider.providerID,
              modelID: modelEntry.id,
              reasoningEffort: effort,
            };
            choices.push([
              agentTargetValue(target),
              `${provider.displayName} · ${modelEntry.displayName}${effort ? ` · ${humanize(effort)}` : ""}`,
            ]);
          });
        });
      });
    return choices;
  }

  function renderTypedAgentModels() {
    const snapshot = state.typedSettings.agentModels;
    if (!snapshot) {
      settingsPage(
        "Agent Models",
        "Loading typed routing settings…",
        "model",
        [],
      );
      return;
    }
    const projectID = state.agent.selectedProjectID;
    const projectOverride =
      Boolean(projectID) && snapshot.projectMode === "projectOverride";
    const scope = desktopCard(
      "Scope",
      "Global routing is shared by every project. An active project may inherit it or own a complete revisioned override.",
    );
    if (projectID) {
      const mode = typedSelect(
        "Agent Models scope",
        [
          ["inheritGlobal", "Use global settings"],
          ["projectOverride", "Use project override"],
        ],
        snapshot.projectMode,
      );
      mode.addEventListener("change", () =>
        mutateDomain(
          "agentModels",
          mode,
          () =>
            api(
              `api/v1/projects/${encodeURIComponent(projectID)}/settings/agent-models`,
              {
                method: "PATCH",
                body: JSON.stringify({
                  expectedRevision: snapshot.projectRevision,
                  mode: mode.value,
                  profile:
                    mode.value === "projectOverride"
                      ? snapshot.projectProfile || snapshot.globalProfile
                      : snapshot.projectProfile,
                }),
              },
            ),
          (value) => {
            state.typedSettings.agentModels = value;
          },
        ),
      );
      scope.append(
        desktopRow(
          "Project routing",
          "Project overrides are complete snapshots. Inherited projects track global edits immediately and keep any unused override snapshot, matching Desktop workspace inherit/override.",
          mode,
        ),
      );
      const copy = element(
        "button",
        "secondary-button",
        "Copy Global to Project",
      );
      copy.type = "button";
      copy.dataset.action = "copy-global-agent-models";
      copy.addEventListener("click", () =>
        mutateDomain(
          "agentModels",
          copy,
          () =>
            api(
              `api/v1/projects/${encodeURIComponent(projectID)}/settings/agent-models/copy-global`,
              {
                method: "POST",
                body: JSON.stringify({
                  expectedGlobalRevision: snapshot.globalRevision,
                  expectedProjectRevision: snapshot.projectRevision,
                }),
              },
            ),
          (value) => {
            state.typedSettings.agentModels = value;
          },
        ),
      );
      scope.append(copy);
      const copyProject = element(
        "button",
        "secondary-button",
        "Copy Project to Global",
      );
      copyProject.type = "button";
      copyProject.dataset.action = "copy-project-agent-models";
      copyProject.addEventListener("click", () =>
        mutateDomain(
          "agentModels",
          copyProject,
          () =>
            api(
              `api/v1/projects/${encodeURIComponent(projectID)}/settings/agent-models/copy-project`,
              {
                method: "POST",
                body: JSON.stringify({
                  expectedGlobalRevision: snapshot.globalRevision,
                  expectedProjectRevision: snapshot.projectRevision,
                }),
              },
            ),
          (value) => {
            state.typedSettings.agentModels = value;
          },
        ),
      );
      scope.append(copyProject);
    } else {
      scope.append(
        element(
          "p",
          "empty-inline",
          "No active project is available; editing the global profile.",
        ),
      );
    }

    const recommendations = desktopCard(
      "Recommended Setup",
      `Server profile ${snapshot.recommendationProfileVersion} is the canonical recommendation authority. OpenCode remains a connection signal but is never invented as a routing target.`,
    );
    (snapshot.recommendations || []).forEach((row) => {
      const provider = orderedProviders().find(
        (candidate) =>
          candidate.providerID === row.recommendedTarget?.providerID,
      );
      const target = row.recommendedTarget;
      const value = target
        ? `${provider?.displayName || target.providerID}${target.modelID ? ` · ${target.modelID}` : ""}${target.reasoningEffort ? ` · ${humanize(target.reasoningEffort)}` : ""}`
        : humanize(row.availability);
      recommendations.append(
        desktopRow(
          humanize(row.target),
          row.detail,
          element(
            "span",
            row.availability === "exact"
              ? "recommended-value"
              : "read-only-value",
            value,
          ),
        ),
      );
    });
    const apply = element(
      "button",
      "primary-button",
      "Apply Recommended Setup",
    );
    apply.type = "button";
    apply.dataset.action = "apply-recommended-agent-models";
    apply.addEventListener("click", () => {
      const projectEndpoint = projectOverride
        ? `api/v1/projects/${encodeURIComponent(projectID)}/settings/agent-models/apply-recommendations`
        : "api/v1/settings/agent-models/apply-recommendations";
      mutateDomain(
        "agentModels",
        apply,
        () =>
          api(projectEndpoint, {
            method: "POST",
            body: JSON.stringify({
              expectedRevision: projectOverride
                ? snapshot.projectRevision
                : snapshot.globalRevision,
            }),
          }),
        (value) => {
          state.typedSettings.agentModels = value;
        },
      );
    });
    recommendations.append(apply);

    const profile = projectOverride
      ? snapshot.projectProfile || snapshot.effectiveProfile
      : snapshot.globalProfile;
    const routes = desktopCard(
      projectOverride ? "Project Agent Routes" : "Global Agent Routes",
      "Oracle and Context Builder fail closed when unassigned. Explore, engineer, pair, and design stay unassigned to track recommendations; an explicit pick is stored even when it matches a recommendation.",
    );
    const form = element("form", "typed-settings-form");
    const targetControls = {};
    [
      "oracle",
      "contextBuilder",
      "explore",
      "engineer",
      "pair",
      "design",
    ].forEach((targetName) => {
      const row = element("div", "typed-route-row");
      const failClosed =
        targetName === "oracle" || targetName === "contextBuilder";
      const select = typedSelect(
        `${humanize(targetName)} route`,
        [
          [
            "",
            failClosed
              ? "Unassigned (fail-closed)"
              : "Unassigned (tracks recommendation)",
          ],
          ...agentTargetChoices().slice(1),
        ],
        agentTargetValue(profile[targetName]),
      );
      row.append(element("strong", "", humanize(targetName)), select);
      form.append(row);
      targetControls[targetName] = { select };
    });
    const restrict = typedToggle(
      "Hide non-role models from MCP agents",
      profile.restrictDiscoveryToRoleModels === true,
    );
    const syncCompose = typedToggle(
      "Sync chat model with Oracle",
      profile.syncChatModelWithOracle === true,
    );
    const composeModel = document.createElement("input");
    composeModel.type = "text";
    composeModel.value = profile.preferredComposeModelRaw || "";
    composeModel.setAttribute("aria-label", "Preferred compose model");
    form.append(
      desktopRow(
        "Hide non-role models from MCP agents",
        "Hides the extra per-agent catalog on agent_manage list_agents. Task labels stay visible. Manually supplied compound IDs are still accepted.",
        restrict.toggle,
      ),
      desktopRow(
        "Sync chat model with Oracle",
        "When on, the compose/chat model live-reads the Oracle model.",
        syncCompose.toggle,
      ),
      desktopRow(
        "Preferred compose model",
        "Raw compose/chat model identifier. Empty tracks Oracle when sync is on.",
        composeModel,
      ),
    );
    const save = element("button", "primary-button", "Save Agent Routes");
    save.type = "submit";
    form.append(save);
    form.addEventListener("submit", (event) => {
      event.preventDefault();
      const nextProfile = {
        ...profile,
        restrictDiscoveryToRoleModels: restrict.input.checked,
        preferredComposeModelRaw: composeModel.value.trim() || null,
        syncChatModelWithOracle: syncCompose.input.checked,
      };
      Object.entries(targetControls).forEach(([name, controls]) => {
        nextProfile[name] = agentTargetFromValue(controls.select.value);
      });
      mutateDomain(
        "agentModels",
        save,
        () =>
          api(
            projectOverride
              ? `api/v1/projects/${encodeURIComponent(projectID)}/settings/agent-models`
              : "api/v1/settings/agent-models",
            {
              method: "PATCH",
              body: JSON.stringify(
                projectOverride
                  ? {
                      expectedRevision: snapshot.projectRevision,
                      mode: "projectOverride",
                      profile: nextProfile,
                    }
                  : {
                      expectedRevision: snapshot.globalRevision,
                      profile: nextProfile,
                    },
              ),
            },
          ),
        (value) => {
          state.typedSettings.agentModels = value;
        },
      );
    });
    routes.append(form);

    const providerDefaults = desktopCard(
      "Provider Defaults",
      "Provider settings remain the exact runtime-backed defaults for explicit portal sessions and unassigned model fields.",
    );
    const stack = element("div", "provider-stack");
    orderedProviders()
      .filter(
        (provider) =>
          provider.deploymentAllowed &&
          provider.category === "cliProvider" &&
          (provider.models || []).length,
      )
      .forEach((provider, index) =>
        stack.append(providerCard(provider, index === 0, true)),
      );
    providerDefaults.append(stack);
    settingsPage(
      "Agent Models",
      "Configure typed global/project routing for Oracle, Context Builder, and all four sub-agent roles.",
      "model",
      [scope, recommendations, routes, providerDefaults],
      recommendation(
        "model",
        snapshot.recommendations.some((row) => row.availability === "exact")
          ? "Recommendation check complete"
          : "No desktop recommendation target available",
        snapshot.recommendations.some((row) => row.availability === "exact")
          ? `Connected providers were evaluated against desktop profile ${snapshot.recommendationProfileVersion} (2026-08).`
          : "The connected provider set has no exact profile target. OpenCode is not assigned to Oracle, Context Builder, or role defaults.",
      ),
    );
  }

  function renderAgentPermissions() {
    const fallback = desktopCard(
      "Portal Session Default",
      "Typed Direct Agents settings are the permission authority. The 3-mode fallback applies only to providers with no typed profile.",
    );
    fallback.append(
      selectSetting(
        "serverDefaultExecutionMode",
        "Default Execution Mode",
        "Session default only for API providers that have no typed Direct Agents profile. It does not replace Codex, Claude, OpenCode, or Cursor permissions.",
        [
          ["readOnly", "Read Only"],
          ["workspaceWrite", "Workspace Write"],
          ["fullAccess", "Full Access"],
        ],
        "workspaceWrite",
      ),
    );
    const byID = Object.fromEntries(
      orderedProviders().map((provider) => [provider.providerID, provider]),
    );
    const snapshot = state.typedSettings.directAgentPermissions;
    const providerCards = [];
    if (snapshot) {
      const settings = snapshot.settings;
      const form = element("form", "typed-settings-form");
      const sandbox = typedSelect(
        "Sandbox",
        [
          ["read-only", "Read Only"],
          ["workspace-write", "Workspace Write"],
          ["danger-full-access", "Full Access"],
        ],
        settings.codex.sandboxMode,
      );
      const approval = typedSelect(
        "Approval Policy",
        [
          ["on-request", "On Request"],
          ["unless-trusted", "Unless Trusted"],
          ["never", "Never"],
        ],
        settings.codex.approvalPolicy,
      );
      const reviewer = typedSelect(
        "Approval Reviewer",
        [
          ["user", "User"],
          ["auto-review", "Auto Review"],
        ],
        settings.codex.approvalReviewer,
      );
      const codexBash = typedToggle("Bash", settings.codex.bashEnabled);
      const claudeMode = typedSelect(
        "Permission Level",
        [
          ["default", "Require Approval"],
          ["acceptEdits", "Auto-Approve Edits"],
          ["auto", "Auto"],
          ["bypassPermissions", "Full Access"],
        ],
        settings.claude.permissionMode,
      );
      const claudeBash = typedToggle("Bash", settings.claude.bashEnabled);
      const claudeStrict = typedToggle(
        "RepoPrompt Only (Strict MCP)",
        settings.claude.mcpStrictModeEnabled,
      );
      const claudePromptDelivery = typedSelect(
        "Sys Prompt Packaging",
        promptDeliveryChoices(),
        settings.claude.promptDelivery || "nativeSystemPrompt",
      );
      const openCodeLevel = typedSelect(
        "ACP Session Mode",
        [
          ["managedDefault", "Managed Default"],
          ["fullAccess", "Full Access"],
        ],
        settings.openCode.permissionLevel,
      );
      const cursorLevel = typedSelect(
        "ACP Auto-Approve",
        [
          ["managedDefault", "Managed Default"],
          ["fullAccess", "Full Access"],
        ],
        settings.cursor.permissionLevel,
      );
      const codexCard = desktopCard(
        "Codex Direct Agent",
        "Independent sandbox, approval, and reviewer fields from the typed Direct Agents store.",
      );
      const derived = element(
        "span",
        "read-only-value",
        liveCodexPermissionLevel(settings.codex),
      );
      codexCard.append(
        desktopRow(
          "Permission Level",
          "Derived from sandbox and reviewer the same way Desktop does.",
          derived,
        ),
        desktopRow(
          "Sandbox",
          "Controls the Codex sandbox boundary for new direct sessions.",
          sandbox,
        ),
        desktopRow(
          "Approval Policy",
          "When Codex must ask before acting.",
          approval,
        ),
        desktopRow(
          "Approval Reviewer",
          "User review or Auto Review for workspace-write sessions.",
          reviewer,
        ),
        desktopRow(
          "Bash",
          "Allow Codex to run shell commands in its approved execution mode.",
          codexBash.toggle,
        ),
      );
      if (byID.codex) {
        codexCard.append(
          element("h3", "desktop-subheading", "Core tools"),
          toggleSetting(
            "codexSearchEnabled",
            "Search",
            "Allow live web search requests from Codex.",
            true,
          ),
          toggleSetting(
            "codexGoalsEnabled",
            "Goals",
            "Enable /goal support and the goal lifecycle for Codex Agent Mode.",
            true,
          ),
          toggleSetting(
            "codexReasoningSummariesEnabled",
            "Reasoning Summaries",
            "Request model reasoning summaries for app-server threads.",
            false,
          ),
          toggleSetting(
            "codexMemoriesEnabled",
            "Local Memories",
            "Allow Codex to generate and use memories in its isolated server home.",
            false,
          ),
          desktopRow(
            "MCP servers",
            "RepoPrompt is required for Agent Mode.",
            element("span", "required-pill", "RepoPrompt · Required"),
          ),
        );
      }
      const claudeCard = desktopCard(
        "Claude Code Direct Agent",
        "Typed Claude permission mode, Bash, and MCP-strict. MCP-strict defaults on.",
      );
      claudeCard.append(
        desktopRow(
          "Permission Level",
          "Controls Claude Code permission prompts.",
          claudeMode,
        ),
        desktopRow(
          "Bash",
          "Allow Claude Code's native Bash tool.",
          claudeBash.toggle,
        ),
        desktopRow(
          "RepoPrompt Only (Strict MCP)",
          "Launch with strict MCP configuration so only RepoPrompt tools are active.",
          claudeStrict.toggle,
        ),
      );
      if (byID.claudeCompatible) {
        claudeCard.append(
          element("h3", "desktop-subheading", "Tools"),
          toggleSetting(
            "claudeToolSearchEnabled",
            "Lazy Tool Loading",
            "Claude searches for each tool before use; this saves context but adds latency.",
            true,
          ),
          desktopRow(
            "Sys Prompt Packaging",
            "Replace Claude Code's native system prompt, wrap RepoPrompt instructions in the user message, or keep the native prompt.",
            claudePromptDelivery,
          ),
        );
      }
      const openCodeCard = desktopCard(
        "OpenCode Direct Agent",
        "Typed ACP session mode from the Direct Agents store.",
      );
      openCodeCard.append(
        desktopRow(
          "ACP Session Mode",
          "Choose the provider's managed mode or full access.",
          openCodeLevel,
        ),
      );
      const cursorCard = desktopCard(
        "Cursor Direct Agent",
        "Typed ACP auto-approve from the Direct Agents store.",
      );
      cursorCard.append(
        desktopRow(
          "ACP Auto-Approve",
          "Choose the provider's managed mode or full access.",
          cursorLevel,
        ),
      );
      const save = element("button", "primary-button", "Save Direct Agents");
      save.type = "submit";
      form.append(codexCard, claudeCard, openCodeCard, cursorCard, save);
      form.addEventListener("submit", (event) => {
        event.preventDefault();
        mutateDomain(
          "directAgentPermissions",
          save,
          () =>
            api("api/v1/settings/direct-agent-permissions", {
              method: "PATCH",
              body: JSON.stringify({
                expectedRevision: snapshot.revision,
                settings: {
                  codex: {
                    sandboxMode: sandbox.value,
                    approvalPolicy: approval.value,
                    approvalReviewer: reviewer.value,
                    bashEnabled: codexBash.input.checked,
                  },
                  claude: {
                    permissionMode: claudeMode.value,
                    bashEnabled: claudeBash.input.checked,
                    mcpStrictModeEnabled: claudeStrict.input.checked,
                    promptDelivery: claudePromptDelivery.value,
                  },
                  openCode: { permissionLevel: openCodeLevel.value },
                  cursor: { permissionLevel: cursorLevel.value },
                },
              }),
            }),
          (value) => {
            state.typedSettings.directAgentPermissions = value;
          },
        );
      });
      providerCards.push(form);
    }
    const subagentSnapshot = state.typedSettings.subagentPermissions;
    const subagents = desktopCard(
      "Sub-Agents",
      "This revisioned policy is frozen into every child session before ProviderExecutionPolicy is created. Missing or corrupt settings fail closed to Safe Managed.",
    );
    if (subagentSnapshot) {
      const form = element("form", "typed-settings-form");
      const settings = subagentSnapshot.settings;
      const policy = typedSelect(
        "Sub-agent permission policy",
        [
          ["safeManaged", "Safe Managed (recommended)"],
          ["inheritProviderSettings", "Inherit Provider Settings"],
          ["custom", "Custom"],
        ],
        settings.policy,
      );
      form.append(
        desktopRow(
          "Policy",
          "Safe Managed resolves Codex to Auto Review, Claude to Require Approval, and ACP providers to Managed Default.",
          policy,
        ),
      );
      const custom = element("div", "subagent-custom-grid");
      const controls = {
        codex: typedSelect(
          "Custom Codex sub-agent mode",
          [
            ["readOnly", "Read Only"],
            ["defaultPermission", "Default Permission"],
            ["autoReview", "Auto Review"],
            ["fullAccess", "Full Access"],
          ],
          settings.codex,
        ),
        claude: typedSelect(
          "Custom Claude sub-agent mode",
          [
            ["requireApproval", "Require Approval"],
            ["autoApproveEdits", "Auto-Approve Edits"],
            ["auto", "Auto"],
            ["fullAccess", "Full Access"],
          ],
          settings.claude,
        ),
        openCode: typedSelect(
          "Custom OpenCode sub-agent mode",
          [
            ["managedDefault", "Managed Default"],
            ["fullAccess", "Full Access"],
          ],
          settings.openCode,
        ),
        cursor: typedSelect(
          "Custom Cursor sub-agent mode",
          [
            ["managedDefault", "Managed Default"],
            ["fullAccess", "Full Access"],
          ],
          settings.cursor,
        ),
      };
      Object.entries(controls).forEach(([name, control]) =>
        custom.append(
          desktopRow(humanize(name), "Custom frozen launch mode.", control),
        ),
      );
      const warning = element(
        "div",
        "inline-message warning",
        "Full Access can allow delegated agents to act without a managed approval boundary.",
      );
      function updateCustomVisibility() {
        custom.hidden = policy.value !== "custom";
        warning.hidden =
          policy.value === "safeManaged" ||
          (policy.value === "custom" &&
            !Object.values(controls).some(
              (control) => control.value === "fullAccess",
            ));
      }
      policy.addEventListener("change", updateCustomVisibility);
      Object.values(controls).forEach((control) =>
        control.addEventListener("change", updateCustomVisibility),
      );
      updateCustomVisibility();
      const save = element("button", "primary-button", "Save Sub-Agent Policy");
      save.type = "submit";
      form.append(custom, warning, save);
      form.addEventListener("submit", (event) => {
        event.preventDefault();
        mutateDomain(
          "subagentPermissions",
          save,
          () =>
            api("api/v1/settings/subagent-permissions", {
              method: "PATCH",
              body: JSON.stringify({
                expectedRevision: subagentSnapshot.revision,
                settings: {
                  policy: policy.value,
                  codex: controls.codex.value,
                  claude: controls.claude.value,
                  openCode: controls.openCode.value,
                  cursor: controls.cursor.value,
                },
              }),
            }),
          (value) => {
            state.typedSettings.subagentPermissions = value;
          },
        );
      });
      subagents.append(form);
    }
    settingsPage(
      "Agent Permissions",
      "Configure runtime-backed direct-agent and delegated sub-agent permissions.",
      "shield",
      [fallback, ...providerCards, subagents],
      recommendation(
        "shield",
        "Direct permissions apply to new sessions",
        "Direct and sub-agent policies are consumed by the server runtime and frozen for new sessions.",
      ),
    );
  }

  function renderTypedAgentWorkflows() {
    const snapshot = state.typedSettings.workflows;
    if (!snapshot) {
      settingsPage(
        "Agent Workflows",
        "Loading workflow repository…",
        "workflow",
        [],
      );
      return;
    }
    const preferences = desktopCard(
      "Workflow Runtime",
      "SQLite is the server-native authoring authority. Definitions are path-free, revisioned, validated, and reloaded into runtime discovery.",
    );
    const cleanup = typedToggle(
      "Include Session Cleanup Guidance",
      snapshot.includeSessionCleanupGuidance,
    );
    cleanup.input.addEventListener("change", () =>
      mutateDomain(
        "workflows",
        cleanup.input,
        () =>
          api("api/v1/workflows/preferences", {
            method: "PATCH",
            body: JSON.stringify({
              expectedRevision: snapshot.revision,
              includeSessionCleanupGuidance: cleanup.input.checked,
            }),
          }),
        (value) => {
          applyWorkflowRepository(value);
        },
      ),
    );
    preferences.append(
      desktopRow(
        "Include Session Cleanup Guidance",
        "Appends bounded cleanup guidance during workflow prompt assembly.",
        cleanup.toggle,
      ),
      element(
        "div",
        "inline-message warning",
        "Hidden workflows are excluded from new discovery. Sessions do not persist a durable workflow association, so hidden-workflow lookup fails closed; re-enable the workflow before starting a new run.",
      ),
    );
    const reload = element("button", "secondary-button", "Reload & Revalidate");
    reload.type = "button";
    reload.addEventListener("click", () =>
      mutateDomain(
        "workflows",
        reload,
        () =>
          api("api/v1/workflows/reload", {
            method: "POST",
            body: JSON.stringify({ expectedRevision: snapshot.revision }),
          }),
        (value) => {
          applyWorkflowRepository(value);
        },
      ),
    );
    preferences.append(reload);

    const catalog = desktopCard(
      "Workflow Catalog",
      "Feature, hide, clone, edit, and delete server-native definitions. Built-ins remain immutable; cloning creates a custom definition.",
    );
    const featured = snapshot.workflows
      .filter((workflow) => workflow.featuredOrder !== null)
      .sort((left, right) => left.featuredOrder - right.featuredOrder);
    const pickerWorkflows = snapshot.workflows
      .filter((workflow) => workflow.enabled && workflow.visible)
      .sort((left, right) => {
        if (left.featuredOrder !== null && right.featuredOrder !== null) {
          return left.featuredOrder - right.featuredOrder;
        }
        if (left.featuredOrder !== null) return -1;
        if (right.featuredOrder !== null) return 1;
        return String(left.name).localeCompare(String(right.name));
      });
    function reorderFeatured(workflowID, delta, control) {
      const ids = featured.map((workflow) => workflow.workflowID);
      const index = ids.indexOf(workflowID);
      const next = index + delta;
      if (index < 0 || next < 0 || next >= ids.length) return;
      [ids[index], ids[next]] = [ids[next], ids[index]];
      mutateDomain(
        "workflows",
        control,
        () =>
          api("api/v1/workflows/reorder", {
            method: "POST",
            body: JSON.stringify({
              expectedRevision: snapshot.revision,
              featuredWorkflowIDs: ids,
            }),
          }),
        (value) => {
          applyWorkflowRepository(value);
        },
      );
    }
    const picker = desktopCard(
      "Picker Catalog",
      "Live discovery from the server repository: enabled and visible rows, featured order first. Hidden built-ins stay in Settings only.",
    );
    picker.dataset.workflowPicker = "server-catalog";
    if (!pickerWorkflows.length) {
      picker.append(
        element(
          "p",
          "scope-footnote",
          "No enabled visible workflows are advertised.",
        ),
      );
    } else {
      const pickerList = element("ol", "workflow-picker-list");
      pickerWorkflows.forEach((workflow) => {
        const item = element("li", "workflow-picker-item");
        item.dataset.workflowId = workflow.workflowID;
        item.dataset.featuredOrder =
          workflow.featuredOrder === null ? "" : String(workflow.featuredOrder);
        item.append(
          element("strong", "", workflow.name),
          element(
            "small",
            "",
            workflow.featuredOrder === null
              ? "Visible"
              : `Featured ${workflow.featuredOrder + 1}`,
          ),
        );
        pickerList.append(item);
      });
      picker.append(pickerList);
    }
    const list = element("div", "workflow-settings-list");
    snapshot.workflows.forEach((workflow) => {
      const details = element("details", "workflow-editor-row");
      const summary = element("summary", "workflow-editor-summary");
      const copy = element("span", "desktop-setting-copy");
      copy.append(
        element("strong", "", workflow.name),
        element(
          "small",
          "",
          `${humanize(workflow.source)} · revision ${workflow.rowRevision}${workflow.featuredOrder !== null ? ` · featured ${workflow.featuredOrder + 1}` : ""}`,
        ),
      );
      summary.append(
        copy,
        element(
          "span",
          workflow.visible ? "connection-badge connected" : "connection-badge",
          workflow.visible ? "Visible" : "Hidden",
        ),
      );
      details.append(summary);
      const actions = element("div", "workflow-inline-actions");
      const visible = element(
        "button",
        "secondary-button",
        workflow.visible ? "Hide" : "Show",
      );
      visible.type = "button";
      visible.addEventListener("click", () =>
        mutateDomain(
          "workflows",
          visible,
          () =>
            api(
              `api/v1/workflows/${encodeURIComponent(workflow.workflowID)}/visibility`,
              {
                method: "PATCH",
                body: JSON.stringify({
                  expectedRevision: snapshot.revision,
                  expectedRowRevision: workflow.rowRevision,
                  visible: !workflow.visible,
                }),
              },
            ),
          (value) => {
            applyWorkflowRepository(value);
          },
        ),
      );
      const clone = element("button", "secondary-button", "Clone");
      clone.type = "button";
      clone.addEventListener("click", () =>
        mutateDomain(
          "workflows",
          clone,
          () =>
            api(
              `api/v1/workflows/${encodeURIComponent(workflow.workflowID)}/clone`,
              {
                method: "POST",
                body: JSON.stringify({
                  expectedRevision: snapshot.revision,
                  expectedSourceRowRevision: workflow.rowRevision,
                  name: `${workflow.name} Copy`,
                }),
              },
            ),
          (value) => {
            applyWorkflowRepository(value);
          },
        ),
      );
      const feature = element(
        "button",
        "secondary-button",
        workflow.featuredOrder === null ? "Feature" : "Unfeature",
      );
      feature.type = "button";
      if (!workflow.visible && workflow.featuredOrder === null) {
        feature.disabled = true;
        feature.title = "Hidden workflows cannot be featured.";
      }
      feature.addEventListener("click", () => {
        const ids = featured
          .map((item) => item.workflowID)
          .filter((id) => id !== workflow.workflowID);
        if (workflow.featuredOrder === null) ids.push(workflow.workflowID);
        mutateDomain(
          "workflows",
          feature,
          () =>
            api("api/v1/workflows/reorder", {
              method: "POST",
              body: JSON.stringify({
                expectedRevision: snapshot.revision,
                featuredWorkflowIDs: ids,
              }),
            }),
          (value) => {
            applyWorkflowRepository(value);
          },
        );
      });
      if (workflow.source === "builtin") {
        actions.append(visible);
      }
      actions.append(clone, feature);
      if (workflow.featuredOrder !== null) {
        const earlier = element("button", "secondary-button", "Move Earlier");
        earlier.type = "button";
        earlier.disabled = workflow.featuredOrder === 0;
        earlier.addEventListener("click", () =>
          reorderFeatured(workflow.workflowID, -1, earlier),
        );
        const later = element("button", "secondary-button", "Move Later");
        later.type = "button";
        later.disabled = workflow.featuredOrder === featured.length - 1;
        later.addEventListener("click", () =>
          reorderFeatured(workflow.workflowID, 1, later),
        );
        actions.append(earlier, later);
      }
      details.append(actions);
      if (workflow.source === "custom") {
        const form = element("form", "workflow-definition-form");
        const name = document.createElement("input");
        name.type = "text";
        name.maxLength = 128;
        name.value = workflow.name;
        name.setAttribute("aria-label", `Workflow name for ${workflow.name}`);
        const definition = document.createElement("textarea");
        definition.rows = 10;
        definition.maxLength = 262144;
        definition.value = workflow.definition;
        definition.setAttribute(
          "aria-label",
          `Markdown definition for ${workflow.name}`,
        );
        const enabled = typedToggle(
          `Enable ${workflow.name}`,
          workflow.enabled,
        );
        const featuredToggle = typedToggle(
          `Feature ${workflow.name}`,
          workflow.featuredOrder !== null,
        );
        const save = element("button", "primary-button", "Save Workflow");
        save.type = "submit";
        const remove = element("button", "danger-button", "Delete");
        remove.type = "button";
        remove.addEventListener("click", async () => {
          if (
            !(await confirmAction({
              title: "Delete workflow?",
              message: `Delete ${workflow.name}?`,
              label: "Delete",
              returnFocus: remove,
            }))
          )
            return;
          mutateDomain(
            "workflows",
            remove,
            () =>
              api(
                `api/v1/workflows/${encodeURIComponent(workflow.workflowID)}`,
                {
                  method: "DELETE",
                  body: JSON.stringify({
                    expectedRevision: snapshot.revision,
                    expectedRowRevision: workflow.rowRevision,
                  }),
                },
              ),
            (value) => {
              applyWorkflowRepository(value);
            },
          );
        });
        form.append(
          desktopRow("Name", "Server-visible workflow name.", name),
          definition,
          desktopRow(
            "Enabled",
            "Admitted to runtime execution.",
            enabled.toggle,
          ),
          desktopRow(
            "Featured",
            "Included in the ordered featured catalog.",
            featuredToggle.toggle,
          ),
          save,
          remove,
        );
        form.addEventListener("submit", (event) => {
          event.preventDefault();
          mutateDomain(
            "workflows",
            save,
            () =>
              api(
                `api/v1/workflows/${encodeURIComponent(workflow.workflowID)}`,
                {
                  method: "PATCH",
                  body: JSON.stringify({
                    expectedRevision: snapshot.revision,
                    expectedRowRevision: workflow.rowRevision,
                    name: name.value.trim(),
                    definition: definition.value,
                    enabled: enabled.input.checked,
                    visible: workflow.visible,
                    featured: featuredToggle.input.checked,
                  }),
                },
              ),
            (value) => {
              applyWorkflowRepository(value);
            },
          );
        });
        details.append(form);
      } else {
        details.append(
          element(
            "p",
            "scope-footnote",
            "Built-in definitions are immutable. Clone this workflow to edit a custom copy.",
          ),
        );
      }
      list.append(details);
    });
    catalog.append(list);

    const create = desktopCard(
      "New Custom Workflow",
      "Create a path-free markdown definition in the server repository. Open Folder and Reveal remain desktop-only local filesystem actions.",
    );
    const createForm = element("form", "workflow-definition-form");
    const name = document.createElement("input");
    name.type = "text";
    name.maxLength = 128;
    name.placeholder = "Workflow name";
    name.setAttribute("aria-label", "New workflow name");
    const definition = document.createElement("textarea");
    definition.rows = 10;
    definition.maxLength = 262144;
    definition.placeholder =
      "# Workflow\n\n## Purpose\nDescribe the workflow.\n\n## Instructions\n- Add bounded steps.";
    definition.setAttribute("aria-label", "New workflow markdown definition");
    const save = element("button", "primary-button", "Create Workflow");
    save.type = "submit";
    if (
      snapshot.workflows.filter((workflow) => workflow.source === "custom")
        .length >= 200
    ) {
      [name, definition, save].forEach((control) =>
        setDisabledReason(
          control,
          true,
          "The server supports at most 200 custom workflows.",
        ),
      );
    }
    createForm.append(name, definition, save);
    createForm.addEventListener("submit", (event) => {
      event.preventDefault();
      mutateDomain(
        "workflows",
        save,
        () =>
          api("api/v1/workflows", {
            method: "POST",
            body: JSON.stringify({
              expectedRevision: snapshot.revision,
              name: name.value.trim(),
              definition: definition.value,
              enabled: true,
              visible: true,
              featured: false,
            }),
          }),
        (value) => {
          applyWorkflowRepository(value);
        },
      );
    });
    create.append(createForm);
    settingsPage(
      "Agent Workflows",
      "Manage the server-native workflow repository and its runtime visibility.",
      "workflow",
      [preferences, picker, catalog, create],
    );
  }

  function renderTypedContextBuilder() {
    const snapshot = state.typedSettings.contextBuilder;
    if (!snapshot) {
      settingsPage(
        "Context Builder",
        "Loading typed Context Builder settings…",
        "context",
        [],
      );
      return;
    }
    const projectID = state.agent.selectedProjectID;
    const projectOverride =
      Boolean(projectID) && snapshot.projectMode === "projectOverride";
    const scope = desktopCard(
      "Scope",
      "Stored defaults resolve explicit invocation override → project override → global setting → typed default.",
    );
    if (projectID) {
      const mode = typedSelect(
        "Context Builder scope",
        [
          ["inheritGlobal", "Use global settings"],
          ["projectOverride", "Use project override"],
        ],
        snapshot.projectMode,
      );
      mode.addEventListener("change", () =>
        mutateDomain(
          "contextBuilder",
          mode,
          () =>
            api(
              `api/v1/projects/${encodeURIComponent(projectID)}/settings/context-builder`,
              {
                method: "PATCH",
                body: JSON.stringify({
                  expectedRevision: snapshot.projectRevision,
                  mode: mode.value,
                  profile:
                    mode.value === "projectOverride"
                      ? snapshot.globalProfile
                      : null,
                }),
              },
            ),
          (value) => {
            state.typedSettings.contextBuilder = value;
          },
        ),
      );
      const copy = element(
        "button",
        "secondary-button",
        "Copy Global to Project",
      );
      copy.type = "button";
      copy.addEventListener("click", () =>
        mutateDomain(
          "contextBuilder",
          copy,
          () =>
            api(
              `api/v1/projects/${encodeURIComponent(projectID)}/settings/context-builder/copy-global`,
              {
                method: "POST",
                body: JSON.stringify({
                  expectedGlobalRevision: snapshot.globalRevision,
                  expectedProjectRevision: snapshot.projectRevision,
                }),
              },
            ),
          (value) => {
            state.typedSettings.contextBuilder = value;
          },
        ),
      );
      scope.append(
        desktopRow(
          "Project defaults",
          "Inherited projects track global settings immediately.",
          mode,
        ),
        copy,
      );
    }

    const profile = JSON.parse(
      JSON.stringify(
        projectOverride
          ? snapshot.projectProfile || snapshot.effectiveProfile
          : snapshot.globalProfile,
      ),
    );
    const settings = desktopCard(
      projectOverride ? "Project Defaults" : "Global Defaults",
      "These values are consumed by Context Builder, including connected chat agents using RepoPrompt MCP and optional follow-up Oracle analysis.",
    );
    const form = element("form", "typed-settings-form");
    const budget = document.createElement("input");
    budget.type = "number";
    budget.min = "10000";
    budget.max = "200000";
    budget.step = "5000";
    budget.value = String(profile.budget);
    budget.setAttribute("aria-label", "Context Budget");
    const enhancement = typedSelect(
      "Prompt Enhancement",
      [
        ["rewrite", "Rewrite"],
        ["augment", "Augment"],
        ["preserve", "Preserve"],
      ],
      profile.enhancementMode,
    );
    const timeout = typedSelect(
      "Question Timeout",
      [
        ["30", "30 seconds"],
        ["60", "1 minute"],
        ["120", "2 minutes"],
        ["300", "5 minutes"],
      ],
      String(profile.questionTimeoutSeconds),
    );
    const clarifyingQuestions = typedToggle(
      "Allow Clarifying Questions",
      profile.mcpClarifyingQuestions,
    );
    const followUp = typedSelect(
      "Follow-up Analysis",
      [
        ["disabled", "Disabled"],
        ["plan", "Plan"],
        ["review", "Review"],
        ["question", "Question"],
      ],
      profile.followUpAnalysis,
    );
    const followUpBudget = document.createElement("input");
    followUpBudget.type = "number";
    followUpBudget.min = "40000";
    followUpBudget.max = "200000";
    followUpBudget.step = "5000";
    followUpBudget.value = String(profile.followUpBudget);
    followUpBudget.setAttribute("aria-label", "Follow-up Analysis Budget");
    form.append(
      desktopRow("Context Budget", "10k–200k in 5k steps.", budget),
      desktopRow(
        "Prompt Enhancement",
        "Rewrite, augment, or preserve caller instructions.",
        enhancement,
      ),
      desktopRow(
        "Question Timeout",
        "Applied to ask_user settlement.",
        timeout,
      ),
      desktopRow(
        "Allow Clarifying Questions",
        "Connected chat agents using RepoPrompt MCP can ask clarifying questions during Context Builder.",
        clarifyingQuestions.toggle,
      ),
      desktopRow(
        "Follow-up Analysis",
        "Runs Oracle after proposal and before committing selection.",
        followUp,
      ),
      desktopRow("Analysis Budget", "40k–200k in 5k steps.", followUpBudget),
    );
    const save = element(
      "button",
      "primary-button",
      "Save Context Builder Settings",
    );
    save.type = "submit";
    form.append(save);
    form.addEventListener("submit", (event) => {
      event.preventDefault();
      const nextProfile = {
        budget: Number(budget.value),
        enhancementMode: enhancement.value,
        questionTimeoutSeconds: Number(timeout.value),
        portalClarifyingQuestions: profile.portalClarifyingQuestions,
        mcpClarifyingQuestions: clarifyingQuestions.input.checked,
        followUpAnalysis: followUp.value,
        followUpBudget: Number(followUpBudget.value),
      };
      mutateDomain(
        "contextBuilder",
        save,
        () =>
          api(
            projectOverride
              ? `api/v1/projects/${encodeURIComponent(projectID)}/settings/context-builder`
              : "api/v1/settings/context-builder",
            {
              method: "PATCH",
              body: JSON.stringify(
                projectOverride
                  ? {
                      expectedRevision: snapshot.projectRevision,
                      mode: "projectOverride",
                      profile: nextProfile,
                    }
                  : {
                      expectedRevision: snapshot.globalRevision,
                      profile: nextProfile,
                    },
              ),
            },
          ),
        (value) => {
          state.typedSettings.contextBuilder = value;
        },
      );
    });
    settings.append(form);

    settingsPage(
      "Context Builder",
      "Configure typed global/project defaults for connected RepoPrompt MCP agents.",
      "context",
      [scope, settings],
    );
  }

  function renderPortalAppearance() {
    const preference = portalAppearance();
    const card = desktopCard(
      "Browser Appearance",
      "These controls are browser-local and apply immediately. They never enter server settings, audit rows, or session state.",
    );
    const theme = typedSelect(
      "Portal theme",
      [
        ["system", "System"],
        ["light", "Light"],
        ["dark", "Dark"],
      ],
      preference.theme,
    );
    const density = typedSelect(
      "Portal text density",
      [
        ["normal", "Normal"],
        ["large", "Large"],
        ["extraLarge", "Extra Large"],
      ],
      preference.density,
    );
    function save() {
      savePortalAppearance({ theme: theme.value, density: density.value });
    }
    theme.addEventListener("change", save);
    density.addEventListener("change", save);
    card.append(
      desktopRow("Theme", "System, light, or dark browser rendering.", theme),
      desktopRow(
        "Text Density",
        "Scales portal typography without changing desktop text-size settings.",
        density,
      ),
    );
    const boundaries = informationalCard(
      "Desktop Appearance Boundary",
      "This page is browser-local chrome. Engine appearance, font scale, tooltips, and keyboard-shortcut persist live on Advanced and MCP app_settings. Headless apply of those keys is a no-op.",
      [
        ["File-change collapsing", "Intentionally omitted"],
        ["Spell checking", "Browser-owned"],
        ["@-mention menu and picker", "Desktop-only"],
      ],
    );
    settingsPage(
      "Portal Appearance",
      "Choose browser-native theme and text density without copying macOS preference keys.",
      "appearance",
      [card, boundaries],
    );
  }

  function renderAdvanced() {
    const snapshot = state.typedSettings.advanced;
    if (!snapshot) {
      settingsPage(
        "Advanced",
        "Loading canonical server settings…",
        "sliders",
        [],
      );
      return;
    }
    const settings = snapshot.settings;
    const card = desktopCard(
      "Server Scanning, Code Maps & History",
      `Revision ${snapshot.revision} is also scanner policy generation ${snapshot.scannerPolicyGeneration}; updates invalidate subsequent scans by generation.`,
    );
    card.append(
      element(
        "div",
        "inline-message warning",
        "Ignore and symlink changes can widen repository scanning. Review project root confinement before saving.",
      ),
    );
    const toggles = {
      respectRepoIgnore: typedToggle(
        "Respect .repo_ignore rules",
        settings.respectRepoIgnore,
      ),
      respectCursorIgnore: typedToggle(
        "Respect .cursorignore rules",
        settings.respectCursorIgnore,
      ),
      respectNestedIgnoreFiles: typedToggle(
        "Respect nested ignore files",
        settings.respectNestedIgnoreFiles,
      ),
      followSymbolicLinks: typedToggle(
        "Follow symbolic links",
        settings.followSymbolicLinks,
      ),
      showEmptyFolders: typedToggle(
        "Show empty folders",
        settings.showEmptyFolders,
      ),
      codeMapsEnabled: typedToggle(
        "Enable Code Maps",
        settings.codeMapsEnabled,
      ),
    };
    Object.entries(toggles).forEach(([key, toggle]) =>
      card.append(
        desktopRow(
          toggle.input.getAttribute("aria-label"),
          key === "codeMapsEnabled"
            ? "Disabling rejects code-map generation and suppresses tool admission."
            : "Consumed by the canonical project scanner.",
          toggle.toggle,
        ),
      ),
    );
    const history = document.createElement("input");
    history.type = "number";
    history.min = "0";
    history.max = "1440";
    history.step = "1";
    history.value = String(settings.historyIdleThresholdMinutes);
    history.setAttribute("aria-label", "Default history idle threshold");
    const globalIgnoreDefaults = document.createElement("textarea");
    globalIgnoreDefaults.rows = 6;
    globalIgnoreDefaults.value =
      settings.globalIgnoreDefaults === undefined
        ? ""
        : String(settings.globalIgnoreDefaults);
    globalIgnoreDefaults.setAttribute("aria-label", "Global ignore defaults");
    card.append(
      desktopRow(
        "History Idle Threshold",
        "0–1440 minutes; omitted history queries use this stored default. Explicit idle_threshold_minutes still fail closed outside that range.",
        history,
      ),
      desktopRow(
        "Global ignore defaults",
        "App-wide gitignore-style patterns. Empty disables app-wide defaults; missing persist live-reads Desktop’s canonical list.",
        globalIgnoreDefaults,
      ),
    );
    const appearance = desktopCard(
      "App Appearance",
      "Persisted for thin clients and MCP app_settings. Headless apply is a no-op. This is not the browser-local Portal Appearance cookie.",
    );
    const appearanceMode = typedSelect(
      "App appearance mode",
      [
        ["System", "System"],
        ["Light", "Light"],
        ["Dark", "Dark"],
      ],
      settings.appearanceMode || "System",
    );
    const fontScale = typedSelect(
      "App font scale",
      [
        ["14", "Normal (14)"],
        ["16", "Large (16)"],
        ["18", "Extra Large (18)"],
      ],
      String(settings.fontScaleBodySize || 14),
    );
    const showTooltips = typedToggle(
      "Show tooltips",
      settings.showTooltips !== false,
    );
    const enableKeyboardShortcuts = typedToggle(
      "Enable keyboard shortcuts",
      settings.enableKeyboardShortcuts !== false,
    );
    appearance.append(
      desktopRow(
        "Appearance mode",
        "System, Light, or Dark. MCP ui.appearance_mode writes this same field.",
        appearanceMode,
      ),
      desktopRow(
        "Font scale",
        "Desktop body sizes 14 / 16 / 18. MCP ui.font_scale writes this same field.",
        fontScale,
      ),
      desktopRow(
        "Show tooltips",
        "Persisted for thin clients. Headless apply is a no-op.",
        showTooltips.toggle,
      ),
      desktopRow(
        "Enable keyboard shortcuts",
        "Persisted for thin clients. Headless apply is a no-op.",
        enableKeyboardShortcuts.toggle,
      ),
    );
    const packaging = desktopCard(
      "Prompt Packaging",
      "Live-read by materialized context, Oracle/copy packaging, and MCP app_settings. There is no separate Copy Prompt Order page.",
    );
    const fileEdit = typedSelect(
      "File edit format",
      [
        ["Diff", "Diff"],
        ["Whole", "Whole"],
        ["None", "None"],
      ],
      settings.fileEditFormat || "Diff",
    );
    const pathDisplay = typedSelect(
      "File path display",
      [
        ["Full", "Full"],
        ["Relative", "Relative"],
      ],
      settings.filePathDisplayOption || "Full",
    );
    const temperatureEnabled = typedToggle(
      "Set model temperature",
      settings.setModelTemperature !== false,
    );
    const temperature = document.createElement("input");
    temperature.type = "number";
    temperature.min = "0";
    temperature.max = "2";
    temperature.step = "0.1";
    temperature.value = String(settings.modelTemperature ?? 0);
    temperature.setAttribute("aria-label", "Model temperature");
    const planning = document.createElement("textarea");
    planning.rows = 4;
    planning.value = settings.customPlanningPrompt || "";
    planning.setAttribute("aria-label", "Custom planning prompt");
    const sectionOrder = document.createElement("input");
    sectionOrder.type = "text";
    sectionOrder.value =
      settings.promptSectionsOrder ||
      '["fileMap","fileContents","gitDiff","metaPrompts","userInstructions"]';
    sectionOrder.setAttribute("aria-label", "Prompt sections order");
    const duplicate = typedToggle(
      "Duplicate user instructions at top",
      settings.duplicateUserInstructionsAtTop === true,
    );
    const datetime = typedToggle(
      "Include datetime in user instructions",
      settings.includeDatetimeInUserInstructions === true,
    );
    packaging.append(
      desktopRow(
        "File edit format",
        "Diff, Whole, or None. Missing or invalid raw live-reads Diff.",
        fileEdit,
      ),
      desktopRow(
        "File path display",
        "Full uses the root path; Relative uses the logical path.",
        pathDisplay,
      ),
      desktopRow(
        "Set model temperature",
        "Off, or a stored 0.0, omits temperature from provider payloads.",
        temperatureEnabled.toggle,
      ),
      desktopRow("Model temperature", "0–2. Live-read when the enable flag is on.", temperature),
      desktopRow(
        "Custom planning prompt",
        "Empty live-reads the built-in Architect fallback.",
        planning,
      ),
      desktopRow(
        "Prompt sections order",
        "JSON array of each section once. Incomplete values live-read the Desktop default.",
        sectionOrder,
      ),
      desktopRow(
        "Duplicate user instructions at top",
        "Prepends user instructions and still emits them in section order.",
        duplicate.toggle,
      ),
      desktopRow(
        "Include datetime in user instructions",
        'Adds date="yyyy-MM-dd\'T\'HH:mm" when packaging user instructions.',
        datetime.toggle,
      ),
    );
    const save = element("button", "primary-button", "Save Advanced Settings");
    save.type = "button";
    save.addEventListener("click", () => {
      const historyIdleThresholdMinutes = Number(history.value);
      if (
        !Number.isInteger(historyIdleThresholdMinutes) ||
        historyIdleThresholdMinutes < 0 ||
        historyIdleThresholdMinutes > 1440
      ) {
        toast(
          "History idle threshold must be an integer from 0 through 1440.",
          true,
        );
        return;
      }
      const modelTemperature = Number(temperature.value);
      if (
        !Number.isFinite(modelTemperature) ||
        modelTemperature < 0 ||
        modelTemperature > 2
      ) {
        toast("Model temperature must be a number from 0 through 2.", true);
        return;
      }
      mutateDomain(
        "advanced",
        save,
        () =>
          api("api/v1/settings/advanced", {
            method: "PATCH",
            body: JSON.stringify({
              expectedRevision: snapshot.revision,
              settings: {
                ...settings,
                ...Object.fromEntries(
                  Object.entries(toggles).map(([key, toggle]) => [
                    key,
                    toggle.input.checked,
                  ]),
                ),
                codeMapsGloballyDisabled: !toggles.codeMapsEnabled.input.checked,
                historyIdleThresholdMinutes,
                globalIgnoreDefaults: globalIgnoreDefaults.value,
                appearanceMode: appearanceMode.value,
                fontScaleBodySize: Number(fontScale.value),
                showTooltips: showTooltips.input.checked,
                enableKeyboardShortcuts: enableKeyboardShortcuts.input.checked,
                fileEditFormat: fileEdit.value,
                customPlanningPrompt: planning.value,
                modelTemperature,
                setModelTemperature: temperatureEnabled.input.checked,
                promptSectionsOrder: sectionOrder.value,
                duplicateUserInstructionsAtTop: duplicate.input.checked,
                filePathDisplayOption: pathDisplay.value,
                includeDatetimeInUserInstructions: datetime.input.checked,
              },
            }),
          }),
        (value) => {
          state.typedSettings.advanced = value;
        },
      );
    });
    packaging.append(save);
    const boundary = informationalCard(
      "Desktop Utility Boundaries",
      "These local desktop integrations have no safe or useful server-setting equivalent and remain input-free.",
      [
        ["Keyboard shortcut link", "Intentionally omitted"],
        ["repoprompt:// URL opener", "macOS-only"],
        [
          "Saved prompt import/export/reset",
          "File-panel utilities; the catalog persists on the server store",
        ],
      ],
    );
    settingsPage(
      "Advanced",
      "Configure only canonical settings consumed by shared-server runtime operations.",
      "sliders",
      [card, appearance, packaging, boundary],
    );
  }

  function renderMCPServer() {
    const tools = state.bootstrap?.tools || [];
    const snapshot = state.typedSettings.showModelPresets;
    if (!snapshot) {
      settingsPage("MCP Server", "Loading MCP server settings…", "server", []);
      return;
    }
    const status = desktopCard(
      "MCP Server",
      "RepoPrompt's MCP surface is part of the shared service lifecycle. Browser users cannot start, stop, or reconfigure the process independently.",
    );
    const toolsLink = element(
      "a",
      "secondary-button compact-link",
      `${tools.length} tools`,
    );
    toolsLink.href = "#settings/mcp-tools";
    toolsLink.dataset.routeLink = "";
    const presets = typedToggle(
      "Use Oracle Model Presets for MCP",
      !!snapshot.settings.showModelPresets,
    );
    presets.input.addEventListener("change", () =>
      saveShowModelPresets(snapshot, presets.input.checked, presets.input),
    );
    status.append(
      desktopRow(
        "Server Status",
        "Deployment-managed and shared by connected agents.",
        element(
          "span",
          state.online ? "required-pill" : "connection-badge attention",
          state.online ? "Running" : "Unavailable",
        ),
      ),
      desktopRow(
        "Use Oracle Model Presets for MCP",
        "When off, list_models omits named presets and ask_oracle / oracle_send fail-closed on preset IDs.",
        presets.toggle,
      ),
      desktopRow(
        "Tools",
        "Canonical catalog advertised by this server build.",
        toolsLink,
      ),
      desktopRow(
        "Context Builder route",
        "The context_builder tool owns shared discovery runs.",
        element("code", "read-only-value", "context_builder"),
      ),
    );
    const desktopBoundary = informationalCard(
      "Desktop Management Boundary",
      "Desktop RepoPrompt owns a per-window MCP process and can expose controls that are not meaningful for this deployment-managed service.",
      [
        [
          "Start / stop / force stop",
          "Deployment-managed",
          "The sandbox service lifecycle is controlled by the deployment workflow.",
        ],
        [
          "Auto-start",
          "Always service-managed",
          "There is no browser window lifecycle to follow.",
        ],
        [
          "Connections dashboard",
          "Not exposed",
          "Client connection details remain server-operational data.",
        ],
        [
          "Quick setup / CLI installer",
          "Desktop-only",
          "Installers modify a local user's tool configuration and filesystem.",
        ],
      ],
    );
    settingsPage(
      "MCP Server",
      "Inspect live shared-server MCP status and the desktop-only process-management boundary.",
      "server",
      [status, desktopBoundary],
    );
  }

  function renderMCPTools() {
    const tools = state.bootstrap?.tools || [];
    const snapshot = state.typedSettings.mcpDisabledTools;
    if (!snapshot) {
      settingsPage("Tools", "Loading MCP tool availability…", "sliders", []);
      return;
    }
    const disabled = new Set(snapshot.settings.disabledTools || []);
    const enabledCount = tools.filter((tool) => !disabled.has(tool.name)).length;
    const card = desktopCard(
      "Advertised MCP Tools",
      "Enable or disable individual MCP tools advertised by this server. Disabled names are omitted from the live catalog and fail closed on invoke.",
    );
    const toolbar = element("div", "tool-catalog-toolbar");
    const searchLabel = element("label", "tool-search-field");
    searchLabel.append(element("span", "sr-only", "Search MCP tools"));
    const search = document.createElement("input");
    search.type = "search";
    search.placeholder = "Search tools";
    search.setAttribute("aria-label", "Search MCP tools");
    searchLabel.append(search);
    const count = element("span", "tool-count");
    count.setAttribute("role", "status");
    toolbar.append(searchLabel, count);
    const list = element("div", "tool-catalog-list");

    function renderToolList() {
      const query = search.value.trim().toLowerCase();
      const filtered = tools.filter((tool) =>
        [tool.name, tool.scope, tool.capability, tool.admissionClass]
          .filter(Boolean)
          .some((value) => String(value).toLowerCase().includes(query)),
      );
      count.textContent = `${filtered.length} of ${tools.length} advertised`;
      list.replaceChildren();
      filtered.forEach((tool) => {
        const row = element("div", "tool-catalog-row");
        const copy = element("div", "tool-catalog-copy");
        copy.append(
          element("code", "tool-name", tool.name),
          element(
            "small",
            "",
            `${humanize(tool.capability)} capability · ${humanize(tool.admissionClass)} admission`,
          ),
        );
        const toggle = typedToggle(tool.name, !disabled.has(tool.name));
        toggle.input.addEventListener("change", () => {
          const next = new Set(disabled);
          if (toggle.input.checked) next.delete(tool.name);
          else next.add(tool.name);
          saveMCPDisabledTools(snapshot, next, toggle.input);
        });
        const badges = element("div", "tool-badges");
        badges.append(
          element("span", "required-pill", humanize(tool.scope)),
          toggle.toggle,
        );
        row.append(copy, badges);
        list.append(row);
      });
      if (!filtered.length)
        list.append(
          element(
            "p",
            "empty-inline",
            "No advertised tools match this search.",
          ),
        );
    }
    search.addEventListener("input", renderToolList);
    renderToolList();
    card.append(toolbar, list);
    settingsPage(
      "Tools",
      "Search and toggle every MCP tool advertised by the shared RepoPrompt runtime.",
      "sliders",
      [card],
      recommendation(
        "check",
        `${enabledCount} of ${tools.length} enabled`,
        "This list is generated from MCPDomainToolCatalog and writes the typed mcp.disabledTools store.",
      ),
    );
  }

  function renderWorkspaceApprovals() {
    const snapshot = state.typedSettings.workspaceApprovals;
    if (!snapshot) {
      settingsPage(
        "Workspace Approvals",
        "Loading workspace approvals…",
        "shield",
        [],
      );
      return;
    }
    const settings = snapshot.settings || {};
    const operations = new Set(settings.autoApproveOperations || []);
    const master = desktopCard(
      "Global Settings",
      "Approvals for RepoPrompt workspace operations (creating folders, deleting workspaces, etc.). CLI agent and sub-agent permissions are configured in Agent Permissions.",
    );
    const autoApproveAll = typedToggle(
      "Auto-approve All Operations",
      !!settings.autoApproveAll,
    );
    autoApproveAll.input.addEventListener("change", () =>
      saveWorkspaceApprovals(
        snapshot,
        (next) => {
          next.autoApproveAll = autoApproveAll.input.checked;
        },
        autoApproveAll.input,
      ),
    );
    master.append(
      desktopRow(
        "Auto-approve All Operations",
        "Skip approval prompts for all workspace operations from all clients.",
        autoApproveAll.toggle,
      ),
    );
    if (settings.autoApproveAll) {
      master.append(
        element(
          "p",
          "empty-inline",
          "All workspace operations will be automatically approved without confirmation.",
        ),
      );
    }
    const perOp = desktopCard(
      "Operation Permissions",
      "Auto-approve specific operations globally. Unlisted operations stay fail-closed unless a trusted client Always Allow matches.",
    );
    workspaceApprovalOperations.forEach(([value, title, detail]) => {
      const toggle = typedToggle(title, operations.has(value));
      toggle.input.disabled = !!settings.autoApproveAll;
      toggle.input.addEventListener("change", () =>
        saveWorkspaceApprovals(
          snapshot,
          (next) => {
            const listed = new Set(next.autoApproveOperations);
            if (toggle.input.checked) listed.add(value);
            else listed.delete(value);
            next.autoApproveOperations = [...listed];
          },
          toggle.input,
        ),
      );
      perOp.append(desktopRow(title, detail, toggle.toggle));
    });
    const trusted = desktopCard(
      "Trusted Clients",
      'Clients that received Always Allow appear here. Chat-server is not a trusted client by default.',
    );
    const policies = Object.values(settings.clientPolicies || {}).sort((left, right) =>
      String(left.clientID || "").localeCompare(String(right.clientID || "")),
    );
    if (policies.length) {
      const reset = element("button", "secondary-button", "Reset All");
      reset.type = "button";
      reset.addEventListener("click", async () => {
        const confirmed = await confirmAction({
          title: "Reset All Trusted Clients?",
          message:
            "This will remove all per-client auto-approve settings. You'll be prompted for approval on future operations.",
          label: "Reset",
          returnFocus: reset,
        });
        if (!confirmed) return;
        saveWorkspaceApprovals(
          snapshot,
          (next) => {
            next.clientPolicies = {};
          },
          reset,
        );
      });
      trusted.append(reset);
      policies.forEach((policy) => {
        const allowed = [...(policy.allowedOperations || [])].join(", ") || "none";
        const revoke = element("button", "secondary-button", "Revoke");
        revoke.type = "button";
        revoke.setAttribute("aria-label", `Revoke ${policy.clientID}`);
        revoke.addEventListener("click", () =>
          saveWorkspaceApprovals(
            snapshot,
            (next) => {
              delete next.clientPolicies[policy.clientID];
            },
            revoke,
          ),
        );
        trusted.append(
          desktopRow(
            policy.clientID || "unknown-client",
            `Always Allow: ${allowed}`,
            revoke,
          ),
        );
      });
    } else {
      trusted.append(
        element(
          "p",
          "empty-inline",
          'No Trusted Clients. When you approve operations with "Always Allow", clients will appear here.',
        ),
      );
    }
    settingsPage(
      "Workspace Approvals",
      "Control automatic approval of the four workspace-management operations. Missing settings stay fail-closed.",
      "shield",
      [master, perOp, trusted],
    );
  }

  function renderTypedModelPresets() {
    const snapshot = state.typedSettings.modelPresets;
    if (!snapshot) {
      settingsPage("Model Presets", "Loading model presets…", "model", []);
      return;
    }
    const presetsGate = state.typedSettings.showModelPresets;
    const card = desktopCard(
      "Oracle Model Presets",
      presetsGate?.settings?.showModelPresets
        ? "This ordered revisioned collection is consumed by list_models, ask_oracle, and oracle_send. Disabled or unavailable targets fail explicitly."
        : "Named presets are hidden from list_models until Use Oracle Model Presets for MCP is enabled on the MCP Server page. ask_oracle and oracle_send fail-closed on preset IDs while the gate is off.",
    );
    const form = element("form", "typed-settings-form");
    const rowsContainer = element("div", "model-preset-rows");
    const rows = [];
    const emptyState = element(
      "p",
      "empty-inline",
      "No model presets configured. Create one from the advertised provider catalog.",
    );
    function syncPresetRows() {
      rows.forEach((row, index) => {
        row.earlier.disabled = index === 0;
        row.later.disabled = index === rows.length - 1;
        rowsContainer.append(row.details);
      });
      if (rows.length === 0) {
        if (!emptyState.isConnected) rowsContainer.append(emptyState);
      } else {
        emptyState.remove();
      }
    }
    function appendPreset(preset) {
      const details = element("details", "model-preset-row");
      const summary = element("summary", "workflow-editor-summary");
      summary.append(
        element("strong", "", preset.name || "New Preset"),
        element(
          "span",
          preset.enabled ? "connection-badge connected" : "connection-badge",
          preset.enabled ? "Enabled" : "Disabled",
        ),
      );
      const name = document.createElement("input");
      name.type = "text";
      name.maxLength = 128;
      name.value = preset.name;
      name.setAttribute("aria-label", "Model preset name");
      const description = document.createElement("textarea");
      description.rows = 3;
      description.maxLength = 1024;
      description.value = preset.description || "";
      description.setAttribute(
        "aria-label",
        `Description for ${preset.name || "preset"}`,
      );
      const target = typedSelect(
        `Model target for ${preset.name || "preset"}`,
        agentTargetChoices().filter(([value]) => value),
        agentTargetValue(preset.target),
      );
      const enabled = typedToggle(
        `Enable ${preset.name || "preset"}`,
        preset.enabled,
      );
      const availability = element("fieldset", "preset-availability");
      availability.append(element("legend", "", "Available modes"));
      const modeInputs = {};
      ["chat", "plan", "review"].forEach((mode) => {
        const label = element("label", "check-row");
        const input = document.createElement("input");
        input.type = "checkbox";
        input.checked = preset.availability.includes(mode);
        modeInputs[mode] = input;
        label.append(input, document.createTextNode(humanize(mode)));
        availability.append(label);
      });
      const actions = element("div", "workflow-inline-actions");
      const earlier = element("button", "secondary-button", "Move Earlier");
      earlier.type = "button";
      const later = element("button", "secondary-button", "Move Later");
      later.type = "button";
      const remove = element("button", "danger-button", "Delete");
      remove.type = "button";
      const record = {
        presetID: preset.presetID,
        name,
        description,
        target,
        enabled: enabled.input,
        modeInputs,
        details,
        earlier,
        later,
      };
      earlier.addEventListener("click", () => {
        const index = rows.indexOf(record);
        if (index <= 0) return;
        [rows[index - 1], rows[index]] = [rows[index], rows[index - 1]];
        syncPresetRows();
      });
      later.addEventListener("click", () => {
        const index = rows.indexOf(record);
        if (index < 0 || index >= rows.length - 1) return;
        [rows[index], rows[index + 1]] = [rows[index + 1], rows[index]];
        syncPresetRows();
      });
      remove.addEventListener("click", async () => {
        if (
          !(await confirmAction({
            title: "Delete model preset?",
            message: `Delete ${name.value.trim() || preset.name || "this model preset"}?`,
            label: "Delete",
            returnFocus: remove,
          }))
        )
          return;
        const index = rows.indexOf(record);
        if (index < 0) return;
        rows.splice(index, 1);
        details.remove();
        syncPresetRows();
      });
      actions.append(earlier, later, remove);
      details.append(
        summary,
        desktopRow("Name", "Unique display and persisted name.", name),
        description,
        desktopRow("Provider / Model", "Exact advertised target.", target),
        desktopRow(
          "Enabled",
          "Available to MCP model resolution.",
          enabled.toggle,
        ),
        availability,
        actions,
      );
      rows.push(record);
      syncPresetRows();
    }
    rowsContainer.append(emptyState);
    snapshot.presets.forEach(appendPreset);
    syncPresetRows();
    const add = element("button", "secondary-button", "Add Preset");
    add.type = "button";
    add.addEventListener("click", () => {
      if (rows.length >= 100) {
        toast("Model Presets supports at most 100 entries.", true);
        return;
      }
      const firstTarget =
        agentTargetChoices().find(([value]) => value)?.[0] || "";
      if (!firstTarget) {
        toast("No advertised model target is available.", true);
        return;
      }
      appendPreset({
        presetID:
          window.crypto?.randomUUID?.() ||
          `00000000-0000-4000-8000-${String(Date.now()).slice(-12).padStart(12, "0")}`,
        name: "New Preset",
        description: null,
        target: agentTargetFromValue(firstTarget),
        availability: ["chat", "plan", "review"],
        enabled: true,
      });
    });
    const save = element("button", "primary-button", "Save Model Presets");
    save.type = "submit";
    const formActions = element(
      "div",
      "workflow-inline-actions model-preset-actions",
    );
    formActions.append(add, save);
    form.append(rowsContainer, formActions);
    form.addEventListener("submit", (event) => {
      event.preventDefault();
      const missingAvailability = rows.find(
        (row) => !Object.values(row.modeInputs).some((input) => input.checked),
      );
      if (missingAvailability) {
        missingAvailability.details.open = true;
        toast(
          "Each model preset must be available in at least one mode.",
          true,
        );
        return;
      }
      mutateDomain(
        "modelPresets",
        save,
        () =>
          api("api/v1/settings/model-presets", {
            method: "PATCH",
            body: JSON.stringify({
              expectedRevision: snapshot.revision,
              presets: rows.map((row, order) => ({
                presetID: row.presetID,
                name: row.name.value.trim(),
                description: row.description.value.trim() || null,
                target: agentTargetFromValue(row.target.value),
                availability: Object.entries(row.modeInputs)
                  .filter(([, input]) => input.checked)
                  .map(([mode]) => mode),
                enabled: row.enabled.checked,
                order,
              })),
            }),
          }),
        (value) => {
          state.typedSettings.modelPresets = value;
        },
      );
    });
    card.append(form);
    settingsPage(
      "Model Presets",
      "Manage named Oracle model routes and their chat, plan, and review availability.",
      "model",
      [card],
    );
  }

  function acceptsPersistedBaseURL(providerID) {
    return ["openAIAPI", "customOpenAICompatible", "azure", "ollama"].includes(
      providerID,
    );
  }

  function acceptsPersistedAPIVersion(providerID) {
    return ["openAIAPI", "customOpenAICompatible", "azure"].includes(providerID);
  }

  function acceptsCustomHeaders(providerID) {
    return ["openRouter", "customOpenAICompatible", "azure"].includes(
      providerID,
    );
  }

  function dedicatedDirectProviderPage(providerID) {
    return ["openRouter", "customOpenAICompatible"].includes(providerID);
  }

  function parseJSONStringMap(raw, label) {
    const parsed = JSON.parse(raw || "{}");
    if (!parsed || Array.isArray(parsed) || typeof parsed !== "object") {
      throw new Error(`${label} must be a JSON object.`);
    }
    const entries = Object.entries(parsed);
    if (entries.length > 16) {
      throw new Error(`At most 16 ${label.toLowerCase()} entries are allowed.`);
    }
    if (entries.some(([, value]) => typeof value !== "string")) {
      throw new Error(`Every ${label.toLowerCase()} value must be a string.`);
    }
    return parsed;
  }

  function parseEnabledModels(raw) {
    const text = String(raw || "").trim();
    if (!text) return [];
    if (text.startsWith("[")) {
      const parsed = JSON.parse(text);
      if (
        !Array.isArray(parsed) ||
        parsed.some((value) => typeof value !== "string")
      ) {
        throw new Error("Enabled models must be a JSON array of strings.");
      }
      return parsed.map((value) => value.trim()).filter(Boolean);
    }
    return text
      .split(/[\n,]/)
      .map((value) => value.trim())
      .filter(Boolean);
  }

  function baseURLCopy(providerID) {
    switch (providerID) {
      case "openAIAPI":
        return [
          "Optional Public HTTPS Base URL",
          "Empty keeps api.openai.com. HTTPS only; private, metadata, and credential-bearing URLs fail closed unless the local-URL escape is enabled.",
        ];
      case "azure":
        return [
          "Azure Resource URL",
          "Public HTTPS Azure resource endpoint. The API key stays in the vault; this field is not a credential bag.",
        ];
      case "ollama":
        return [
          "Ollama URL",
          "Desktop default is http://localhost:11434. Persist is allowed; execute still requires REPOPROMPT_ALLOW_LOCAL_PROVIDER_URLS=1.",
        ];
      default:
        return [
          "Public HTTPS Base URL",
          "HTTPS port 443 only; DNS is re-resolved and pinned for every request. Private, local, metadata, mixed, redirecting, and credential-bearing endpoints fail closed.",
        ];
    }
  }

  function directProviderCard(provider) {
    const configuration =
      state.typedSettings.directConfigurations[provider.providerID];
    const card = desktopCard(provider.displayName, provider.summary);
    card.dataset.providerId = provider.providerID;
    card.append(
      desktopRow(
        "Enabled",
        "A direct provider becomes launchable only after deployment admission, validated connection, sanitized catalog, and registered runtime all agree.",
        providerEnabledToggle(provider),
      ),
    );
    if (configuration) {
      const form = element("form", "typed-settings-form direct-provider-form");
      const persistBaseURL = acceptsPersistedBaseURL(provider.providerID);
      const persistAPIVersion = acceptsPersistedAPIVersion(provider.providerID);
      const persistHeaders = acceptsCustomHeaders(provider.providerID);
      const persistAllowlist = [
        "openRouter",
        "customOpenAICompatible",
      ].includes(provider.providerID);
      const baseURL = document.createElement("input");
      baseURL.type = provider.providerID === "ollama" ? "text" : "url";
      baseURL.value = configuration.baseURL || "";
      baseURL.placeholder =
        provider.providerID === "ollama"
          ? "http://localhost:11434"
          : "https://provider.example/v1";
      baseURL.setAttribute("aria-label", `${provider.displayName} base URL`);
      const apiVersion = document.createElement("input");
      apiVersion.type = "text";
      apiVersion.maxLength = 64;
      apiVersion.value = configuration.apiVersion || "";
      apiVersion.placeholder = "Optional API version";
      apiVersion.setAttribute(
        "aria-label",
        `${provider.displayName} API version`,
      );
      const preferredModel = document.createElement("input");
      preferredModel.type = "text";
      preferredModel.maxLength = 256;
      preferredModel.value = configuration.preferredModel || "";
      preferredModel.placeholder = "Provider default / auto-detect";
      preferredModel.setAttribute(
        "aria-label",
        `${provider.displayName} preferred model`,
      );
      const maximum = document.createElement("input");
      maximum.type = "number";
      maximum.min = "0";
      maximum.max = "65536";
      maximum.step = "1";
      maximum.value = String(configuration.maximumOutputTokens ?? 0);
      maximum.setAttribute(
        "aria-label",
        `${provider.displayName} maximum output tokens`,
      );
      const headers = document.createElement("textarea");
      headers.rows = 4;
      headers.value = JSON.stringify(
        configuration.customHeaders || {},
        null,
        2,
      );
      headers.setAttribute(
        "aria-label",
        `${provider.displayName} custom headers`,
      );
      const enabledModels = document.createElement("textarea");
      enabledModels.rows = 3;
      enabledModels.value = (configuration.enabledModels || []).join("\n");
      enabledModels.placeholder = "One model ID per line";
      enabledModels.setAttribute(
        "aria-label",
        `${provider.displayName} enabled models`,
      );
      const includeDefaultModels = typedToggle(
        `${provider.displayName} include default models`,
        configuration.includeDefaultModels !== false,
      );
      const useCustomSettings = typedToggle(
        `${provider.displayName} use custom settings`,
        configuration.useCustomSettings !== false,
      );
      const includeContentTypeHeader = typedToggle(
        `${provider.displayName} persist Content-Type header`,
        Boolean(configuration.includeContentTypeHeader),
      );
      const showServiceTierVariants = typedToggle(
        `${provider.displayName} show service-tier variants`,
        Boolean(configuration.showServiceTierVariants),
      );
      if (persistBaseURL) {
        const [label, detail] = baseURLCopy(provider.providerID);
        form.append(desktopRow(label, detail, baseURL));
      }
      if (persistAPIVersion) {
        form.append(
          desktopRow(
            "API Version",
            "Optional path or query version. Empty uses the provider default.",
            apiVersion,
          ),
        );
      }
      form.append(
        desktopRow(
          "Preferred Model",
          "Optional exact catalog ID; empty uses provider selection.",
          preferredModel,
        ),
        desktopRow(
          "Maximum Output Tokens",
          "0 omits the stored limit and uses the Desktop model default. Range is 0 through 65,536.",
          maximum,
        ),
      );
      if (provider.providerID === "openAIAPI") {
        form.append(
          desktopRow(
            "Show Service-Tier Variants",
            "When on, the live catalog keeps Desktop service-tier variants. This is not the leftover openAIServiceTier string bag.",
            showServiceTierVariants.toggle,
          ),
        );
      }
      if (provider.providerID === "openRouter") {
        form.append(
          desktopRow(
            "Use Custom Settings",
            "When off, OpenRouter still sends HTTP-Referer / X-Title and ignores stored tokens and extra headers.",
            useCustomSettings.toggle,
          ),
          desktopRow(
            "Include Default Models",
            "When off, picker and launch are limited to the enabled-model allowlist plus preferred.",
            includeDefaultModels.toggle,
          ),
        );
      }
      if (persistAllowlist) {
        form.append(
          desktopRow(
            "Enabled Models",
            "Allowlist IDs, one per line. Preferred is always included. Custom picker/launch is this set only.",
            enabledModels,
          ),
        );
      }
      if (provider.providerID === "customOpenAICompatible") {
        form.append(
          desktopRow(
            "Persist Content-Type Header Flag",
            "Stored only. Live requests stay application/json unless a custom header overrides Content-Type.",
            includeContentTypeHeader.toggle,
          ),
        );
      }
      if (persistHeaders) {
        form.append(
          desktopRow(
            "Custom Headers (JSON)",
            "Authorization, cookies, host/forwarding headers, controls, oversized values, and likely secrets are rejected.",
            headers,
          ),
        );
      }
      form.append(
        desktopRow(
          "Content-Type",
          "Fixed by the runtime; not a credential-bearing override.",
          element("span", "read-only-value", "application/json"),
        ),
      );
      const save = element(
        "button",
        "primary-button",
        "Save Runtime Configuration",
      );
      save.type = "submit";
      const editable = [
        baseURL,
        apiVersion,
        preferredModel,
        maximum,
        headers,
        enabledModels,
        includeDefaultModels.input,
        useCustomSettings.input,
        includeContentTypeHeader.input,
        showServiceTierVariants.input,
      ];
      if (provider.connection) {
        editable.forEach((control) =>
          setDisabledReason(
            control,
            true,
            "Disconnect the provider before changing runtime configuration.",
          ),
        );
        setDisabledReason(
          save,
          true,
          "Disconnect the provider before changing runtime configuration.",
        );
      }
      form.append(save);
      form.addEventListener("submit", (event) => {
        event.preventDefault();
        let customHeaders = {};
        let allowlisted = [];
        try {
          customHeaders = persistHeaders
            ? parseJSONStringMap(headers.value, "Headers")
            : {};
          allowlisted = persistAllowlist
            ? parseEnabledModels(enabledModels.value)
            : [];
        } catch (error) {
          toast(error.message, true);
          return;
        }
        const maximumOutputTokens = Number(maximum.value);
        if (
          !Number.isInteger(maximumOutputTokens) ||
          maximumOutputTokens < 0 ||
          maximumOutputTokens > 65536
        ) {
          toast(
            "Maximum output tokens must be an integer from 0 through 65,536.",
            true,
          );
          return;
        }
        mutateDomain(
          "directConfigurations",
          save,
          () =>
            api(
              `api/v1/provider-settings/${encodeURIComponent(provider.providerID)}/direct-configuration`,
              {
                method: "PATCH",
                body: JSON.stringify({
                  expectedRevision: configuration.revision,
                  baseURL: persistBaseURL ? baseURL.value.trim() || null : null,
                  preferredModel: preferredModel.value.trim() || null,
                  maximumOutputTokens,
                  customHeaders,
                  contentTypePolicy: "applicationJSON",
                  apiVersion: persistAPIVersion
                    ? apiVersion.value.trim() || null
                    : null,
                  enabledModels: allowlisted,
                  includeDefaultModels: includeDefaultModels.input.checked,
                  useCustomSettings: useCustomSettings.input.checked,
                  includeContentTypeHeader:
                    includeContentTypeHeader.input.checked,
                  showServiceTierVariants:
                    showServiceTierVariants.input.checked,
                }),
              },
            ),
          (value) => {
            state.typedSettings.directConfigurations[provider.providerID] =
              value;
          },
        );
      });
      card.append(form);
    }
    if (provider.authentication?.authenticated) {
      card.append(connectedProviderSummary(provider));
    } else {
      const direct = (provider.capabilities.authenticationMethods || []).filter(
        (method) => directAuthenticationMethods.has(method),
      );
      if (direct.length) card.append(credentialForm(provider, direct));
      else
        card.append(
          element(
            "p",
            "empty-inline",
            "No write-only browser credential method is advertised by the completed backend contract.",
          ),
        );
    }
    return card;
  }

  function renderTypedAPIProviders() {
    const providers = orderedProviders().filter(
      (provider) =>
        provider.category === "apiProvider" &&
        provider.deploymentAllowed &&
        !dedicatedDirectProviderPage(provider.providerID),
    );
    const cards = providers.map(directProviderCard);
    cards.push(
      informationalCard(
        "Unsupported Provider Boundaries",
        "No inert credential or endpoint controls are rendered for protocols outside the completed backend truth contract.",
        [["LM Studio", "Intentionally omitted local-network protocol"]],
      ),
    );
    settingsPage(
      "API Providers",
      "Configure every deployment-admitted direct HTTPS runtime. OpenRouter and custom OpenAI-compatible keep their dedicated pages. Credentials stay on the connection APIs.",
      "cloud",
      cards,
    );
  }

  function renderTypedOpenRouter() {
    const provider = orderedProviders().find(
      (candidate) =>
        candidate.providerID === "openRouter" && candidate.deploymentAllowed,
    );
    const cards = provider
      ? [directProviderCard(provider)]
      : [
          informationalCard(
            "OpenRouter Deployment Boundary",
            "This deployment does not advertise the complete OpenRouter runtime. Credential, token, header, and model controls remain input-free.",
            [["Status", "Deployment-disabled"]],
          ),
        ];
    settingsPage(
      "OpenRouter",
      "Configure fixed-host OpenRouter only when validation, catalog, vault, and execution truth are all advertised.",
      "cloud",
      cards,
    );
  }

  function renderTypedCustomAPI() {
    const provider = orderedProviders().find(
      (candidate) =>
        candidate.providerID === "customOpenAICompatible" &&
        candidate.deploymentAllowed,
    );
    const cards = provider
      ? [directProviderCard(provider)]
      : [
          informationalCard(
            "Custom API Deployment Boundary",
            "This deployment does not advertise the hardened custom OpenAI-compatible runtime. Endpoint and credential controls remain input-free.",
            [
              ["Required policy", "Public HTTPS/443 + pinned-address egress"],
              ["Status", "Deployment-disabled"],
            ],
          ),
        ];
    settingsPage(
      "Custom API",
      "Configure a custom provider only through the completed SSRF-safe validation and request runtime.",
      "sliders",
      cards,
    );
  }

  function renderModelConfig() {
    const catalog = desktopCard(
      "Advertised Model Catalog",
      "Read-only models and option families supplied by the live provider settings service.",
    );
    const list = element("div", "model-config-list");
    orderedProviders().forEach((provider) =>
      (provider.models || []).forEach((model) => {
        const row = element("div", "model-config-row");
        const copy = element("div", "desktop-setting-copy");
        copy.append(
          element("strong", "", model.displayName),
          element("small", "", `${provider.displayName} · ${model.id}`),
        );
        const options = [
          ...(model.reasoningEfforts || []).map(
            (value) => `reasoning:${value}`,
          ),
          ...(model.speedModes || []).map((value) => `speed:${value}`),
          ...(model.serviceTiers || []).map((value) => `tier:${value}`),
        ];
        row.append(
          copy,
          element(
            "span",
            "model-option-summary",
            options.length ? options.join(" · ") : "Provider defaults",
          ),
        );
        list.append(row);
      }),
    );
    if (!list.childElementCount)
      list.append(element("p", "empty-inline", "No models are advertised."));
    catalog.append(list);
    const desktop = informationalCard(
      "Desktop Per-Model Overrides",
      "The desktop model registry can mutate capabilities that the shared-server DTO does not yet expose. OpenAI service tier belongs to API Providers, not this page.",
      [
        ["Allow Diff", "Per model", "Controls diff-based edit support."],
        ["Streaming", "Per model", "Overrides streaming capability."],
        [
          "Responses API",
          "Custom providers",
          "Selects the OpenAI Responses transport when applicable.",
        ],
        ["Temperature", "Slider + reset", "Overrides the model temperature."],
      ],
    );
    settingsPage(
      "Model Config",
      "Inspect live model capabilities and the desktop-only override boundary.",
      "model",
      [catalog, desktop],
    );
  }

  function renderManageWorkspaces() {
    const projects = state.bootstrap?.projects || [];
    const card = desktopCard(
      "Server Projects",
      "Live projects provisioned for this shared service. Root paths are reduced to browser-safe root names.",
    );
    const list = element("div", "workspace-project-list");
    projects.forEach((project) => {
      const roots = project.rootNames || [];
      list.append(
        desktopRow(
          project.name || project.projectId,
          roots.length ? roots.join(" · ") : "No roots advertised",
          element("span", "required-pill", humanize(project.state)),
        ),
      );
    });
    if (!projects.length)
      list.append(
        element("p", "empty-inline", "No server projects are available."),
      );
    card.append(list);
    const desktop = informationalCard(
      "Desktop Workspace Management",
      "Desktop RepoPrompt can select arbitrary local folders and manage window workspaces. A browser cannot safely mirror those local filesystem operations on the server.",
      [
        [
          "Auto-restore",
          "Desktop-only",
          "Restores local windows and workspace state.",
        ],
        [
          "Global storage / duplicate cleanup",
          "Desktop-only",
          "Manages the local workspace database.",
        ],
        [
          "Create workspace / add folders",
          "Operator-provisioned here",
          "Server project roots are configured outside the portal.",
        ],
        [
          "Switch / rename / hide / delete",
          "No portal mutation API",
          "The portal consumes project snapshots but does not own their lifecycle.",
        ],
        [
          "Session worktrees",
          "Per-session runtime API",
          "Worktree behavior is selected when agents run; the removed portal defaults were never consumed.",
        ],
      ],
    );
    settingsPage(
      "Manage Workspaces",
      "Review live shared projects and the desktop-only local-workspace boundary.",
      "folder",
      [card, desktop],
    );
  }

  function renderTypedManagePresets() {
    const snapshot = state.typedSettings.selectionPresets;
    const project = selectedProject();
    const session = selectedSession();
    if (!project || !snapshot) {
      const boundary = informationalCard(
        "No Active Server Project",
        "Selection presets are project-scoped and cannot be edited without an operator-provisioned project.",
        [["Project lifecycle", "Operator / deployment boundary"]],
      );
      settingsPage(
        "Manage Presets",
        "Manage named file-selection presets for the active server project.",
        "listStar",
        [boundary],
      );
      return;
    }
    const card = desktopCard(
      `${project.name} Selection Presets`,
      "Named presets capture logical root-confined selections. Apply and capture fence both the collection revision and live session selection revision.",
    );
    const list = element("div", "selection-preset-list");
    function orderedIDsWithMove(presetID, delta) {
      const ids = snapshot.presets.map((preset) => preset.presetID);
      const index = ids.indexOf(presetID);
      const next = index + delta;
      if (index < 0 || next < 0 || next >= ids.length) return null;
      [ids[index], ids[next]] = [ids[next], ids[index]];
      return ids;
    }
    snapshot.presets.forEach((preset, index) => {
      const row = element("section", "selection-preset-row");
      const name = document.createElement("input");
      name.type = "text";
      name.maxLength = 256;
      name.value = preset.name;
      name.setAttribute("aria-label", `Preset name for ${preset.name}`);
      const actions = element("div", "workflow-inline-actions");
      const rename = element("button", "secondary-button", "Save Name");
      rename.type = "button";
      rename.addEventListener("click", () =>
        mutateDomain(
          "selectionPresets",
          rename,
          () =>
            api(
              `api/v1/projects/${encodeURIComponent(project.projectId)}/selection-presets/${encodeURIComponent(preset.presetID)}`,
              {
                method: "PATCH",
                body: JSON.stringify({
                  expectedCollectionRevision: snapshot.revision,
                  expectedRowRevision: preset.rowRevision,
                  name: name.value.trim(),
                  entries: preset.entries,
                }),
              },
            ),
          (value) => {
            state.typedSettings.selectionPresets = value;
          },
        ),
      );
      const apply = element("button", "primary-button", "Apply to Session");
      apply.type = "button";
      const selection = session
        ? state.typedSettings.selections[session.sessionId]
        : null;
      if (!session || !selection) {
        setDisabledReason(
          apply,
          true,
          "Select a session with a loaded selection before applying a preset.",
        );
      } else {
        apply.addEventListener("click", () =>
          mutateDomain(
            "selectionPresets",
            apply,
            () =>
              api(
                `api/v1/projects/${encodeURIComponent(project.projectId)}/selection-presets/apply`,
                {
                  method: "POST",
                  body: JSON.stringify({
                    presetID: preset.presetID,
                    expectedCollectionRevision: snapshot.revision,
                    sessionID: session.sessionId,
                    expectedSelectionRevision: selection.revision,
                  }),
                },
              ),
            (value) => {
              state.typedSettings.selections[session.sessionId] = value;
            },
          ),
        );
      }
      const earlier = element("button", "secondary-button", "Move Earlier");
      earlier.type = "button";
      earlier.disabled = index === 0;
      earlier.addEventListener("click", () => {
        const ids = orderedIDsWithMove(preset.presetID, -1);
        if (!ids) return;
        mutateDomain(
          "selectionPresets",
          earlier,
          () =>
            api(
              `api/v1/projects/${encodeURIComponent(project.projectId)}/selection-presets/reorder`,
              {
                method: "POST",
                body: JSON.stringify({
                  expectedCollectionRevision: snapshot.revision,
                  orderedPresetIDs: ids,
                }),
              },
            ),
          (value) => {
            state.typedSettings.selectionPresets = value;
          },
        );
      });
      const later = element("button", "secondary-button", "Move Later");
      later.type = "button";
      later.disabled = index === snapshot.presets.length - 1;
      later.addEventListener("click", () => {
        const ids = orderedIDsWithMove(preset.presetID, 1);
        if (!ids) return;
        mutateDomain(
          "selectionPresets",
          later,
          () =>
            api(
              `api/v1/projects/${encodeURIComponent(project.projectId)}/selection-presets/reorder`,
              {
                method: "POST",
                body: JSON.stringify({
                  expectedCollectionRevision: snapshot.revision,
                  orderedPresetIDs: ids,
                }),
              },
            ),
          (value) => {
            state.typedSettings.selectionPresets = value;
          },
        );
      });
      const remove = element("button", "danger-button", "Delete");
      remove.type = "button";
      remove.addEventListener("click", async () => {
        if (
          !(await confirmAction({
            title: "Delete selection preset?",
            message: `Delete ${preset.name}? Active selections are not changed.`,
            label: "Delete",
            returnFocus: remove,
          }))
        )
          return;
        mutateDomain(
          "selectionPresets",
          remove,
          () =>
            api(
              `api/v1/projects/${encodeURIComponent(project.projectId)}/selection-presets/${encodeURIComponent(preset.presetID)}`,
              {
                method: "DELETE",
                body: JSON.stringify({
                  expectedCollectionRevision: snapshot.revision,
                  expectedRowRevision: preset.rowRevision,
                }),
              },
            ),
          (value) => {
            state.typedSettings.selectionPresets = value;
          },
        );
      });
      actions.append(rename, apply, earlier, later, remove);
      row.append(
        name,
        element(
          "small",
          "scope-footnote",
          `${preset.entries.length} selection entr${preset.entries.length === 1 ? "y" : "ies"} · row revision ${preset.rowRevision}`,
        ),
        actions,
      );
      list.append(row);
    });
    if (!snapshot.presets.length) {
      list.append(
        element(
          "p",
          "empty-inline",
          "No named selection presets exist for this project.",
        ),
      );
    }
    card.append(list);
    const capture = desktopCard(
      "Capture Current Session",
      "Save the currently selected session files as a new named project preset.",
    );
    if (session && state.typedSettings.selections[session.sessionId]) {
      const selection = state.typedSettings.selections[session.sessionId];
      const form = element("form", "typed-settings-form compact-form");
      const name = document.createElement("input");
      name.type = "text";
      name.maxLength = 256;
      name.placeholder = "Preset name";
      name.setAttribute("aria-label", "New selection preset name");
      const save = element("button", "primary-button", "Capture Preset");
      save.type = "submit";
      if (snapshot.presets.length >= 100) {
        [name, save].forEach((control) =>
          setDisabledReason(
            control,
            true,
            "The server supports at most 100 named selection presets per project.",
          ),
        );
      }
      form.append(name, save);
      form.addEventListener("submit", (event) => {
        event.preventDefault();
        mutateDomain(
          "selectionPresets",
          save,
          () =>
            api(
              `api/v1/projects/${encodeURIComponent(project.projectId)}/selection-presets/capture`,
              {
                method: "POST",
                body: JSON.stringify({
                  expectedCollectionRevision: snapshot.revision,
                  sessionID: session.sessionId,
                  expectedSelectionRevision: selection.revision,
                  name: name.value.trim(),
                }),
              },
            ),
          (value) => {
            state.typedSettings.selectionPresets = value;
          },
        );
      });
      capture.append(form);
    } else {
      capture.append(
        element(
          "p",
          "empty-inline",
          "Select an existing session before capturing a preset.",
        ),
      );
    }
    settingsPage(
      "Manage Presets",
      "Manage project-scoped named file selections, not Agent Workflows or prompt presets.",
      "listStar",
      [card, capture],
    );
  }

  function liveRouteAssignment(target) {
    return state.typedSettings.agentModels?.effectiveProfile?.[target] || null;
  }

  function liveRouteStatus(target) {
    const assigned = liveRouteAssignment(target);
    if (!assigned) {
      return target === "oracle" || target === "contextBuilder"
        ? "Unconfigured"
        : "Tracks recommendation";
    }
    const provider = orderedProviders().find(
      (candidate) => candidate.providerID === assigned.providerID,
    );
    return `${provider?.displayName || assigned.providerID}${assigned.modelID ? ` · ${assigned.modelID}` : ""}${assigned.reasoningEffort ? ` · ${humanize(assigned.reasoningEffort)}` : ""}`;
  }

  function liveRouteDetail(target) {
    if (target === "oracle" || target === "contextBuilder") {
      return "Fail-closed when unassigned. Live-read from the typed Agent Models store.";
    }
    return "Empty tracks the recommendation. An explicit pick stays stored.";
  }

  function liveAgentModelsStatus() {
    const snapshot = state.typedSettings.agentModels;
    if (!snapshot) return "Loading";
    const profile = snapshot.effectiveProfile || {};
    if (profile.oracle || profile.contextBuilder) return liveRouteStatus("oracle");
    return orderedProviders().some(isConnectedProvider)
      ? "Recommendations ready"
      : "Connect a CLI provider";
  }

  function liveCodexPermissionLevel(codex) {
    if (!codex) return "Auto Review";
    if (codex.sandboxMode === "read-only") return "Read Only";
    if (codex.sandboxMode === "danger-full-access") return "Full Access";
    return codex.approvalReviewer === "auto-review"
      ? "Auto Review"
      : "Default Permission";
  }

  function liveSandboxLabel(mode) {
    return (
      {
        "read-only": "Read Only",
        "workspace-write": "Workspace Write",
        "danger-full-access": "Full Access",
      }[mode] || mode
    );
  }

  function liveClaudePermissionLabel(mode) {
    return (
      {
        default: "Require Approval",
        acceptEdits: "Auto-Approve Edits",
        auto: "Auto",
        bypassPermissions: "Full Access",
      }[mode] || mode
    );
  }

  function livePromptDeliveryLabel(mode) {
    return (
      {
        nativeSystemPrompt: "Replace System Prompt",
        userMessageXMLWithEmptySystemPrompt: "User Message (No Native)",
        userMessageXML: "User Message (Keep Native)",
      }[mode] || "Replace System Prompt"
    );
  }

  function liveManagedPermissionLabel(providerID) {
    const settings = state.typedSettings.directAgentPermissions?.settings;
    const level =
      providerID === "cursorACP"
        ? settings?.cursor?.permissionLevel
        : settings?.openCode?.permissionLevel;
    return level === "fullAccess" ? "Full Access" : "Managed Default";
  }

  function liveDirectAgentStatus() {
    const settings = state.typedSettings.directAgentPermissions?.settings;
    if (!settings) return "Loading";
    return `Codex ${liveSandboxLabel(settings.codex.sandboxMode)} · ${liveCodexPermissionLevel(settings.codex)}`;
  }

  function liveSubagentStatus() {
    const policy = state.typedSettings.subagentPermissions?.settings?.policy;
    if (policy === "safeManaged") return "Safe Managed";
    if (policy === "inheritProviderSettings") return "Inherit";
    if (policy === "custom") return "Custom";
    return "Editable";
  }

  function renderOverview() {
    const content = document.getElementById("settings-content");
    disposeSensitiveInputs(content);
    content.replaceChildren(
      pageHeader(
        "Agent Mode",
        "Oracle reasons, Context Builder gathers files, and agents do the work. Each row links to the canonical page that owns the available server setting.",
        "agent",
      ),
    );

    const byID = Object.fromEntries(
      orderedProviders().map((provider) => [provider.providerID, provider]),
    );
    const mainCLIProviders = [
      byID.codex,
      byID.claudeCompatible,
      byID.openCodeACP,
      byID.cursorACP,
    ].filter(Boolean);
    const connected = mainCLIProviders.filter(isConnectedProvider);
    const routes = desktopCard(
      "Agent Setup",
      "Canonical destinations and live shared-server status.",
    );
    function routeRow(title, detail, route, statusText) {
      const link = element("a", "overview-route-row");
      link.href = `#settings/${route}`;
      link.dataset.routeLink = "";
      const copy = element("div", "desktop-setting-copy");
      copy.append(element("strong", "", title), element("small", "", detail));
      link.append(
        copy,
        element("span", "read-only-value", statusText),
        iconNode("chevron"),
      );
      routes.append(link);
    }
    routeRow(
      "Agent Models",
      "Typed global/project routes plus server profile 202_608 recommendations.",
      "agent-models",
      liveAgentModelsStatus(),
    );
    routeRow(
      "CLI Providers",
      "Codex, Claude Code, compatible backends, OpenCode, and Cursor.",
      "cli-providers",
      `${connected.length} of ${mainCLIProviders.length} connected`,
    );
    routeRow(
      "Context Builder",
      "Typed defaults for connected RepoPrompt MCP agents.",
      "context-builder",
      "Editable",
    );
    routeRow(
      "Agent Workflows",
      "Built-in and custom workflow catalog advertised by the server.",
      "agent-workflows",
      `${state.typedSettings.workflows?.workflows?.length || 0} managed`,
    );
    routeRow(
      "Agent Permissions",
      "Typed Direct Agents plus Safe Managed, Inherit, and Custom sub-agent policy.",
      "agent-permissions",
      liveDirectAgentStatus(),
    );
    content.append(routes);
    const liveRoutes = desktopCard(
      "Live routing",
      "Effective Oracle, Context Builder, and role defaults from the typed Agent Models store.",
    );
    [
      ["oracle", "Oracle"],
      ["contextBuilder", "Context Builder"],
      ["explore", "Explore"],
      ["engineer", "Engineer"],
      ["pair", "Pair"],
      ["design", "Design"],
    ].forEach(([target, title]) => {
      liveRoutes.append(
        desktopRow(
          title,
          liveRouteDetail(target),
          element("span", "read-only-value", liveRouteStatus(target)),
        ),
      );
    });
    content.append(liveRoutes);

    const livePermissions = desktopCard(
      "Live permissions",
      "Effective Direct Agents and Sub-Agents policy from the typed permission store.",
    );
    const permissionSettings =
      state.typedSettings.directAgentPermissions?.settings;
    const subagentSettings =
      state.typedSettings.subagentPermissions?.settings;
    [
      [
        "Codex",
        permissionSettings
          ? `${liveSandboxLabel(permissionSettings.codex.sandboxMode)} · ${liveCodexPermissionLevel(permissionSettings.codex)}`
          : "Loading",
        "Independent sandbox, approval, and reviewer. Not the 3-mode fallback.",
      ],
      [
        "Claude",
        permissionSettings
          ? `${liveClaudePermissionLabel(permissionSettings.claude.permissionMode)} · ${livePromptDeliveryLabel(permissionSettings.claude.promptDelivery)}`
          : "Loading",
        "Typed permission mode, Bash, MCP-strict, and Sys Prompt Packaging.",
      ],
      [
        "OpenCode",
        liveManagedPermissionLabel("openCodeACP"),
        "Typed ACP session mode.",
      ],
      [
        "Cursor",
        liveManagedPermissionLabel("cursorACP"),
        "Typed ACP auto-approve.",
      ],
      [
        "Sub-Agents",
        liveSubagentStatus(),
        "Safe Managed, Inherit, or Custom frozen into child sessions.",
      ],
    ].forEach(([title, status, detail]) => {
      livePermissions.append(
        desktopRow(title, detail, element("span", "read-only-value", status)),
      );
    });
    content.append(livePermissions);

    const providerCard = desktopCard(
      "CLI Provider Status",
      "The desktop overview summarizes every CLI provider in one place.",
    );
    const providerList = element("div", "provider-status-list");
    mainCLIProviders.forEach((provider) => {
      const status = providerStatus(provider);
      providerList.append(
        desktopRow(
          desktopProviderPresentation(provider).title,
          provider.cli?.version
            ? `CLI ${provider.cli.version}`
            : provider.cli?.installed === false
              ? "CLI not installed"
              : "CLI status available in provider details",
          element(
            "span",
            `connection-badge ${status.tone}`.trim(),
            status.label,
          ),
        ),
      );
    });
    providerCard.append(providerList);
    content.append(providerCard);

    const defaults = desktopCard(
      "Portal Session Default",
      "Thin-client fallback for providers with no typed Direct Agents profile. Typed Codex, Claude, OpenCode, and Cursor permissions win.",
    );
    defaults.append(
      selectSetting(
        "serverDefaultExecutionMode",
        "Execution Mode",
        "Session default only when no typed permission profile applies.",
        [
          ["readOnly", "Read Only"],
          ["workspaceWrite", "Workspace Write"],
          ["fullAccess", "Full Access"],
        ],
        "workspaceWrite",
      ),
    );
    content.append(defaults);

    content.append(
      informationalCard(
        "Desktop-Only Overview Behaviors",
        "These controls depend on desktop window/provider-conversation features that the portal session API does not implement.",
        [
          [
            "Show chats created by MCP tools",
            "Desktop Compose only",
            "Controls visibility of local app chats before an agent runs.",
          ],
          [
            "Provider Conversation Cleanup",
            "Archive / Delete",
            "Runs when desktop Agent Mode sessions are removed; portal deletion has no equivalent provider-conversation contract.",
          ],
          [
            "Handoff Instructions",
            "Multiline Save / Clear",
            "App-wide text appended by the desktop titlebar Handoff action; the portal has no Handoff action.",
          ],
        ],
      ),
    );
    installIcons(content);
  }

  function renderProviders(category, title, subtitle) {
    const content = document.getElementById("settings-content");
    disposeSensitiveInputs(content);
    content.replaceChildren(
      pageHeader(
        title,
        subtitle,
        category === "cliProvider" ? "terminal" : "cloud",
      ),
      recommendation(
        "shield",
        "Write-only credentials",
        "Credential values are sent only to the authenticated server connection endpoint. They are cleared from the DOM after every success or failure and never returned by the catalog.",
      ),
    );
    const stack = element("div", "provider-stack");
    const providers = orderedProviders().filter(
      (provider) =>
        provider.category === category && provider.deploymentAllowed,
    );
    if (!providers.length) {
      const empty = element("div", "empty-state-panel");
      empty.append(
        element("h2", "", "No providers in this category"),
        element(
          "p",
          "",
          "The server catalog does not currently advertise a configurable provider here.",
        ),
      );
      stack.append(empty);
    } else {
      providers.forEach((provider, index) =>
        stack.append(providerCard(provider, index === 0, false)),
      );
    }
    content.append(stack);
    installIcons(content);
  }

  function providerCard(provider, open, modelsOnly) {
    const presentation = desktopProviderPresentation(provider);
    const details = element("details", "provider-card");
    details.open = open;
    details.dataset.providerId = provider.providerID;
    const summary = document.createElement("summary");
    const status = providerStatus(provider);
    const badge = element("span", `connection-badge ${status.tone}`.trim());
    badge.append(element("i"), element("span", "", status.label));
    const name = element("span", "provider-name");
    name.append(
      element("strong", "", presentation.title),
      element("small", "", presentation.subtitle),
    );
    summary.append(
      iconNode(
        provider.category === "cliProvider" ? "terminal" : "cloud",
        "provider-glyph",
      ),
      name,
      badge,
      iconNode("chevron"),
    );
    const body = element("div", "provider-card-body");
    body.append(settingsSection(provider));
    if (!modelsOnly) body.append(authenticationSection(provider));
    details.append(summary, body);
    return details;
  }

  function statusTile(label, value, detail) {
    const tile = element("div", "status-tile");
    tile.append(
      element("span", "", label),
      element("strong", "", value),
      element("small", "", detail || "—"),
    );
    return tile;
  }

  function sectionHeading(title, detail) {
    const heading = element("div", "provider-section-heading");
    const copy = element("div");
    copy.append(element("h3", "", title), element("p", "", detail));
    heading.append(copy);
    return heading;
  }

  function appendFieldHelp(form, text) {
    form.append(element("span", "field-help", text));
  }

  function addSelect(form, labelText, name, emptyLabel) {
    const label = element("label", "", labelText);
    const select = document.createElement("select");
    select.name = name;
    select.setAttribute("aria-label", labelText);
    populateSelect(
      select,
      [],
      "",
      (value) => value,
      (value) => value,
      emptyLabel,
    );
    form.append(label, select);
    return select;
  }

  function populateSelect(select, values, selected, label, key, emptyLabel) {
    select.replaceChildren();
    const empty = element("option", "", emptyLabel);
    empty.value = "";
    select.append(empty);
    values.forEach((value) => {
      const option = element("option", "", label(value));
      option.value = key(value);
      option.selected = option.value === selected;
      select.append(option);
    });
  }

  function setSelectAvailability(select, available, reason) {
    setDisabledReason(select, !available, reason);
    if (!available) select.value = "";
  }

  function settingsSection(provider) {
    const section = element("section", "provider-section");
    section.dataset.controlFamily = "provider-preferences";
    section.append(
      sectionHeading(
        "Provider defaults",
        "Revisioned settings contain no credential material.",
      ),
    );
    const form = element("form", "settings-form");
    form.dataset.providerSettings = provider.providerID;

    const enabledLabel = element("label", "", "Provider");
    const enabledRow = element("div", "toggle-row");
    const toggle = element("label", "toggle");
    const enabled = document.createElement("input");
    enabled.type = "checkbox";
    enabled.name = "enabled";
    enabled.checked = provider.preference.enabled;
    enabled.setAttribute("aria-label", `Enable ${provider.displayName}`);
    const deploymentReason =
      provider.providerID === "xAI"
        ? "This provider has no portable server runtime yet."
        : "Deployment configuration does not allow this provider runtime.";
    setDisabledReason(enabled, !provider.deploymentAllowed, deploymentReason);
    toggle.append(enabled, element("span"));
    const enabledText = element(
      "span",
      "",
      enabled.checked ? "Enabled" : "Disabled",
    );
    enabledRow.append(toggle, enabledText);
    form.append(enabledLabel, enabledRow);
    if (!provider.deploymentAllowed) appendFieldHelp(form, deploymentReason);

    const model = addSelect(
      form,
      "Default model",
      "defaultModel",
      "Provider default",
    );
    populateSelect(
      model,
      provider.models || [],
      provider.preference.defaultModel || "",
      (item) => item.displayName,
      (item) => item.id,
      "Provider default",
    );
    const modelReason = !provider.capabilities.supportsModelSelection
      ? "This provider does not support model selection."
      : "No sanitized model catalog is available for this provider account.";
    setSelectAvailability(
      model,
      provider.capabilities.supportsModelSelection &&
        provider.models.length > 0,
      modelReason,
    );
    if (model.disabled) appendFieldHelp(form, modelReason);

    const effort = addSelect(
      form,
      "Reasoning effort",
      "reasoningEffort",
      "Model default",
    );
    const speed = addSelect(form, "Fast mode", "speedMode", "Standard speed");
    const tier = addSelect(
      form,
      "Service tier",
      "serviceTier",
      "Standard tier",
    );

    function refreshDependentOptions(initial = false) {
      const selectedModel = provider.models.find(
        (item) => item.id === model.value,
      );
      const currentEffort = initial
        ? provider.preference.reasoningEffort
        : effort.value;
      const currentSpeed = initial
        ? provider.preference.speedMode
        : speed.value;
      const currentTier = initial
        ? provider.preference.serviceTier
        : tier.value;
      const efforts = selectedModel?.reasoningEfforts || [];
      const speeds = selectedModel?.speedModes || [];
      const tiers = selectedModel?.serviceTiers || [];
      populateSelect(
        effort,
        efforts,
        efforts.includes(currentEffort) ? currentEffort : "",
        humanize,
        (value) => value,
        "Model default",
      );
      populateSelect(
        speed,
        speeds,
        speeds.includes(currentSpeed) ? currentSpeed : "",
        humanize,
        (value) => value,
        "Standard speed",
      );
      populateSelect(
        tier,
        tiers,
        tiers.includes(currentTier) ? currentTier : "",
        humanize,
        (value) => value,
        "Standard tier",
      );
      setSelectAvailability(
        effort,
        provider.capabilities.supportsReasoningEffort && efforts.length > 0,
        !provider.capabilities.supportsReasoningEffort
          ? "Reasoning effort is not supported by this provider."
          : "Choose a model that advertises reasoning effort values.",
      );
      setSelectAvailability(
        speed,
        provider.capabilities.supportsSpeedMode && speeds.length > 0,
        !provider.capabilities.supportsSpeedMode
          ? "Fast mode is not supported by this provider."
          : "The selected model does not advertise fast-mode values.",
      );
      setSelectAvailability(
        tier,
        provider.capabilities.supportsServiceTier && tiers.length > 0,
        !provider.capabilities.supportsServiceTier
          ? "Service tier is not supported by this provider."
          : "The selected model does not advertise service-tier values.",
      );
    }
    refreshDependentOptions(true);

    const message = element(
      "div",
      "inline-message info form-message",
      "Change a setting to save a new revision.",
    );
    message.setAttribute("role", "status");
    message.tabIndex = -1;
    const actions = element("div", "form-actions");
    const note = element(
      "span",
      "form-note",
      "Disabling blocks new runs; it does not terminate work already in flight.",
    );
    const save = element("button", "primary-button", "Save Settings");
    save.type = "submit";
    save.dataset.action = "save-provider-settings";
    setDisabledReason(save, true, "Change a setting to save.");
    actions.append(note, save);
    form.append(message, actions);

    function markDirty() {
      enabledText.textContent = enabled.checked ? "Enabled" : "Disabled";
      setDisabledReason(save, false, "");
      message.textContent = "Unsaved changes";
      message.className = "inline-message info form-message";
    }
    enabled.addEventListener("change", markDirty);
    model.addEventListener("change", () => {
      refreshDependentOptions(false);
      markDirty();
    });
    [effort, speed, tier].forEach((select) =>
      select.addEventListener("change", markDirty),
    );

    form.addEventListener("submit", async (event) => {
      event.preventDefault();
      if (save.disabled) return;
      const originalLabel = save.textContent;
      setDisabledReason(save, true, "Settings are being saved.");
      save.textContent = "Saving…";
      form.setAttribute("aria-busy", "true");
      message.textContent = "Saving provider settings…";
      try {
        const updated = await api(
          `api/v1/provider-settings/${encodeURIComponent(provider.providerID)}`,
          {
            method: "PATCH",
            body: JSON.stringify({
              expectedRevision: provider.preference.revision,
              enabled: enabled.checked,
              defaultModel: model.value || null,
              reasoningEffort: effort.value || null,
              speedMode: speed.value || null,
              serviceTier: tier.value || null,
            }),
          },
        );
        replaceProvider(updated);
        renderHomeProviders();
        renderRoute();
        toast(`${provider.displayName} settings saved`);
        announce(`${provider.displayName} settings saved`);
      } catch (error) {
        message.textContent =
          error.code === "staleRevision"
            ? `${error.message} Refresh the catalog before trying again.`
            : error.message;
        message.className = "inline-message error form-message";
        message.focus({ preventScroll: true });
        save.textContent = originalLabel;
        setDisabledReason(save, false, "");
        toast(error.message, true);
      } finally {
        form.removeAttribute("aria-busy");
      }
    });

    section.append(form);
    return section;
  }

  function authFlowForMethod(flows, method) {
    return (
      flows.find((flow) => flow.kind === method) ||
      (method === "browserLogin" || method === "providerSpecific"
        ? flows.find((flow) => flow.kind === "externalProvisioning")
        : null)
    );
  }

  function authenticationMethodName(provider, method, flow) {
    if (flow?.displayName) return flow.displayName;
    if (provider.providerID === "codex" && method === "browserOAuth")
      return "Login with ChatGPT";
    if (provider.providerID === "codex" && method === "deviceCodeBeta")
      return "Use device code instead";
    if (provider.providerID === "codex" && method === "apiKey")
      return "OpenAI API Key";
    return humanize(method);
  }

  function authenticationMethodDescription(provider, method, flow) {
    if (flow?.detail) return flow.detail;
    if (
      provider.providerID === "codex" &&
      (method === "browserOAuth" || method === "deviceCodeBeta")
    )
      return "Uses your Codex subscription. RepoPrompt CE keeps this sign-in separate from ~/.codex.";
    if (provider.providerID === "codex" && method === "apiKey")
      return "API keys for direct model access. OpenAI API usage is API-billed.";
    return provider.authentication?.detail || provider.summary;
  }

  function authenticationMethodChoices(provider, flowMessage) {
    const choices = element("div", "auth-choice-grid");
    const flows = provider.capabilities.authFlows || [];
    const methods = (provider.capabilities.authenticationMethods || []).filter(
      (method) =>
        provider.providerID !== "codex" ||
        !directAuthenticationMethods.has(method),
    );
    if (provider.providerID === "codex") {
      const releaseOrder = ["deviceCodeBeta", "browserOAuth", "apiKey"];
      methods.sort((left, right) => {
        const leftIndex = releaseOrder.indexOf(left);
        const rightIndex = releaseOrder.indexOf(right);
        return (
          (leftIndex < 0 ? 99 : leftIndex) - (rightIndex < 0 ? 99 : rightIndex)
        );
      });
    }
    methods.forEach((method) => {
      const flow = authFlowForMethod(flows, method);
      const methodName = authenticationMethodName(provider, method, flow);
      const card = element("div", "auth-choice");
      card.dataset.authenticationMethod = method;
      const copy = element("div", "auth-choice-copy");
      copy.append(
        element("strong", "", methodName),
        element(
          "small",
          "",
          authenticationMethodDescription(provider, method, flow),
        ),
      );
      const active = provider.connection?.authenticationMethod === method;
      const activelyConnected =
        active && provider.connection?.state === "connected";
      const direct = directAuthenticationMethods.has(method);
      const action = element(
        "button",
        active
          ? "secondary-button auth-choice-action active"
          : "secondary-button auth-choice-action",
        activelyConnected
          ? "Connected"
          : active
            ? "Reconnect"
            : direct
              ? provider.connection
                ? "Change"
                : "Validate & Save"
              : methodName,
      );
      action.type = "button";
      action.dataset.action = direct ? "choose-auth-method" : "start-auth-flow";
      if (flow) action.dataset.flowKind = flow.kind;
      const anotherFlow =
        state.activeFlow && state.activeFlow.providerID !== provider.providerID;
      if (activelyConnected) {
        setDisabledReason(
          action,
          true,
          "This is the current connection method.",
        );
      } else if (direct) {
        action.addEventListener("click", () => {
          const select = card
            .closest(".provider-card")
            ?.querySelector('.secret-form select[name="authenticationMethod"]');
          if (!select) return;
          select.value = method;
          select.dispatchEvent(new window.Event("change", { bubbles: true }));
          select.focus({ preventScroll: true });
        });
      } else if (!flow?.startable || anotherFlow) {
        setDisabledReason(
          action,
          true,
          anotherFlow
            ? "Finish or cancel the active authentication flow first."
            : flow?.detail ||
                "This server does not advertise a startable adapter for this method.",
        );
      } else {
        action.addEventListener("click", () =>
          startAuthFlow(provider, flow, action, flowMessage),
        );
      }
      card.append(copy, action);
      choices.append(card);
    });
    return choices;
  }

  function authenticationSection(provider) {
    const section = element("section", "provider-section");
    section.dataset.controlFamily = "authentication";
    section.append(
      sectionHeading(
        "Connection & authentication",
        "Only methods advertised by this provider are rendered.",
      ),
    );

    if (provider.providerID === "codex") {
      const note = element("p", "codex-auth-note");
      note.append(
        document.createTextNode(
          "ChatGPT may require identity verification (KYC) to access Codex. ",
        ),
      );
      const learnMore = element("a", "", "Learn more");
      learnMore.href = "https://chatgpt.com/cyber";
      learnMore.target = "_blank";
      learnMore.rel = "noopener noreferrer";
      note.append(learnMore);
      section.append(note);
      if (!provider.authentication?.authenticated)
        section.append(
          element(
            "p",
            "card-subtitle codex-permissions-note",
            "Permissions and runtime controls appear here after Codex is connected.",
          ),
        );
    }

    const advertisedFlowDetail =
      provider.capabilities.authFlows?.find((flow) => flow.startable)?.detail ||
      provider.capabilities.authFlows?.[0]?.detail ||
      provider.authentication?.detail ||
      "No authentication flow detail is available.";
    const flowMessage = element(
      "div",
      "inline-message info auth-flow-message",
      provider.providerID === "codex"
        ? "RepoPrompt CE keeps checking this separate Codex sign-in while it is pending."
        : advertisedFlowDetail,
    );
    flowMessage.setAttribute("role", "status");
    flowMessage.tabIndex = -1;
    section.append(authenticationMethodChoices(provider, flowMessage));

    if (provider.connection) section.append(connectionPanel(provider));

    const directMethods = provider.capabilities.authenticationMethods.filter(
      (method) => directAuthenticationMethods.has(method),
    );
    if (directMethods.length)
      section.append(credentialForm(provider, directMethods));

    const hasTransientMethod = provider.capabilities.authenticationMethods.some(
      (method) => transientAuthenticationMethods.has(method),
    );
    if (hasTransientMethod) {
      section.append(flowMessage);
      if (state.activeFlow?.providerID === provider.providerID)
        section.append(devicePanel(provider));
    }

    if (!provider.capabilities.authenticationMethods.length) {
      const unavailable = element("div", "unavailable-panel");
      unavailable.append(
        iconNode("info"),
        document.createTextNode(
          "No browser-manageable authentication operation is advertised. Configure this provider in its isolated server account.",
        ),
      );
      section.append(unavailable);
    }
    return section;
  }

  function connectionPanel(provider) {
    const connection = provider.connection;
    const panel = element("div", "settings-card connection-panel");
    const activeFlow = authFlowForMethod(
      provider.capabilities.authFlows || [],
      connection.authenticationMethod,
    );
    panel.append(
      element(
        "h2",
        "",
        provider.providerID === "codex"
          ? "Signed in to Codex"
          : "Current connection",
      ),
      element(
        "p",
        "card-subtitle",
        `${authenticationMethodName(provider, connection.authenticationMethod, activeFlow)} · ${connection.accountLabel || "No account label"}`,
      ),
    );
    const grid = element("div", "provider-status-grid connection-details");
    grid.append(
      statusTile(
        "State",
        humanize(connection.state),
        connection.detail || "No additional detail",
      ),
      statusTile(
        "Credential test",
        humanize(connection.testState),
        connection.lastTestedAt
          ? formatDate(connection.lastTestedAt)
          : "Never tested",
      ),
      statusTile(
        "Expires",
        formatDate(connection.expiresAt, "No expiration reported"),
        connection.keyHelperConfigured
          ? "Key helper configured"
          : connection.workloadIdentityConfigured
            ? "Workload identity configured"
            : "Server-managed credential",
      ),
      statusTile(
        "Updated",
        formatDate(connection.updatedAt),
        `Created ${formatDate(connection.createdAt)}`,
      ),
    );
    panel.append(grid);

    const message = element(
      "div",
      "inline-message info",
      "Testing never returns credential material.",
    );
    message.setAttribute("role", "status");
    message.tabIndex = -1;
    const actions = element("div", "provider-actions-footer");
    const testButton = element("button", "secondary-button", "Test Connection");
    testButton.type = "button";
    testButton.dataset.action = "test-connection";
    testButton.addEventListener("click", () =>
      runConnectionAction(provider, "test", testButton, message),
    );
    const destructive = element("div", "button-row");
    const disconnect = element("button", "danger-button subtle", "Disconnect");
    disconnect.type = "button";
    disconnect.dataset.action = "request-disconnect";
    disconnect.addEventListener("click", async () => {
      const accepted = await confirmAction({
        title: `Disconnect ${provider.displayName}?`,
        message:
          "The stored credential will be deleted and new runs will no longer use this connection.",
        label: "Disconnect",
        returnFocus: disconnect,
      });
      if (accepted)
        await runConnectionAction(provider, "disconnect", disconnect, message);
    });
    const revoke = element("button", "danger-button", "Revoke & Disconnect");
    revoke.type = "button";
    revoke.dataset.action = "request-revoke";
    revoke.addEventListener("click", async () => {
      const accepted = await confirmAction({
        title: `Revoke ${provider.displayName} access?`,
        message:
          "The server will request provider logout, delete its stored credential, and record a revocation audit entry.",
        label: "Revoke & Disconnect",
        returnFocus: revoke,
      });
      if (accepted)
        await runConnectionAction(provider, "revoke", revoke, message);
    });
    destructive.append(disconnect, revoke);
    actions.append(testButton, destructive);
    panel.append(message, actions);
    return panel;
  }

  async function runConnectionAction(provider, operation, button, message) {
    const originalLabel = button.textContent;
    const labels = {
      test: "Testing…",
      disconnect: "Disconnecting…",
      revoke: "Revoking…",
    };
    button.textContent = labels[operation];
    setDisabledReason(button, true, `${humanize(operation)} is in progress.`);
    message.textContent = labels[operation];
    try {
      const updated = await api(
        `api/v1/provider-settings/${encodeURIComponent(provider.providerID)}/${operation}`,
        {
          method: "POST",
          body: "{}",
        },
      );
      replaceProvider(updated);
      renderHomeProviders();
      renderRoute();
      const result =
        operation === "test"
          ? `${provider.displayName} connection tested`
          : `${provider.displayName} ${operation === "revoke" ? "revoked and disconnected" : "disconnected"}`;
      toast(result);
      announce(result);
    } catch (error) {
      message.textContent = error.message;
      message.className = "inline-message error";
      message.focus({ preventScroll: true });
      button.textContent = originalLabel;
      setDisabledReason(button, false, "");
      toast(error.message, true);
    }
  }

  function credentialForm(provider, methods, options = {}) {
    const wrapper = element("div", "settings-card credential-card");
    const codexAPIKey =
      provider.providerID === "codex" && methods.includes("apiKey");
    const hasDirectConnection = methods.includes(
      provider.connection?.authenticationMethod,
    );
    wrapper.append(
      element(
        "h2",
        "",
        options.title ||
          (codexAPIKey
            ? "OpenAI API Key"
            : hasDirectConnection
              ? "Change connection"
              : "Add connection"),
      ),
      element(
        "p",
        "card-subtitle",
        options.subtitle ||
          (codexAPIKey
            ? "API keys for direct model access. OpenAI API usage is API-billed."
            : "Credential fields are write-only and are disposed after every request outcome."),
      ),
    );
    const form = element("form", "secret-form");
    form.dataset.providerConnect = provider.providerID;
    const methodLabel = element("label", "", "Authentication method");
    const method = document.createElement("select");
    method.name = "authenticationMethod";
    method.setAttribute("aria-label", "Authentication method");
    methods.forEach((value) => {
      const option = element("option", "", humanize(value));
      option.value = value;
      method.append(option);
    });
    const fields = element("div", "credential-fields");
    const message = element(
      "div",
      "inline-message info form-message",
      "The server never returns the submitted value.",
    );
    message.setAttribute("role", "status");
    message.tabIndex = -1;
    const actions = element("div", "form-actions");
    const note = element(
      "span",
      "form-note",
      "Use a least-privilege credential scoped to this sandbox server.",
    );
    const submit = element(
      "button",
      "primary-button",
      hasDirectConnection ? "Change" : "Validate & Save",
    );
    submit.type = "submit";
    submit.dataset.action = "connect-provider";
    actions.append(note, submit);
    if (methods.length > 1) form.append(methodLabel, method);
    form.append(fields, message, actions);

    function addInput(name, labelText, options = {}) {
      const label = element("label", "", labelText);
      label.htmlFor = `${provider.providerID}-${name}`;
      const input = document.createElement("input");
      input.id = `${provider.providerID}-${name}`;
      input.name = name;
      input.type = options.type || "text";
      input.required = options.required === true;
      input.autocomplete = "off";
      input.spellcheck = false;
      input.setAttribute("autocapitalize", "none");
      if (options.placeholder) input.placeholder = options.placeholder;
      if (options.minLength) input.minLength = options.minLength;
      if (options.sensitive) input.dataset.sensitive = "true";
      fields.append(label, input);
      if (options.help)
        fields.append(element("span", "field-help", options.help));
      return input;
    }

    function renderFields() {
      disposeSensitiveInputs(fields);
      fields.replaceChildren();
      const selected = method.value;
      if (["apiKey", "enterpriseAccessToken", "authToken"].includes(selected)) {
        addInput("credential", humanize(selected), {
          type: "password",
          required: true,
          minLength: 8,
          sensitive: true,
          placeholder: "Enter write-only credential",
          help: "Required. Between 8 and 65,536 bytes; never echoed by the server.",
        });
        addInput("accountLabel", "Account label", {
          placeholder: "Optional non-secret label",
          help: "Do not paste credential material into the label.",
        });
      } else if (selected === "keyHelper") {
        addInput("keyHelperCommand", "Key helper executable", {
          required: true,
          sensitive: true,
          placeholder: "/absolute/path/to/helper",
          help: "Claude only. Enter an absolute executable path without arguments or whitespace.",
        });
      } else if (selected === "workloadIdentityFederation") {
        addInput("workloadIdentityProvider", "Identity provider", {
          required: true,
          placeholder: "Non-secret provider identifier",
        });
        addInput("workloadIdentityServiceAccount", "Service account", {
          required: true,
          placeholder: "Non-secret service account label",
        });
      } else {
        fields.append(
          element(
            "p",
            "field-wide form-note",
            "No raw credential is proxied. This creates a server-side provider-specific connection record; complete authentication in the isolated provider account.",
          ),
        );
      }
    }
    method.addEventListener("change", renderFields);
    renderFields();

    form.addEventListener("submit", async (event) => {
      event.preventDefault();
      const payload = { authenticationMethod: method.value };
      fields.querySelectorAll("input[name]").forEach((input) => {
        const value = input.value.trim();
        if (value) payload[input.name] = value;
      });
      let requestBody = JSON.stringify(payload);
      const originalLabel = submit.textContent;
      form.setAttribute("aria-busy", "true");
      form.querySelectorAll("input, select, button").forEach((control) => {
        setDisabledReason(control, true, "Connection request is in progress.");
      });
      submit.textContent = hasDirectConnection ? "Saving…" : "Validating…";
      message.textContent = "Sending the write-only connection request…";
      try {
        const updated = await api(
          `api/v1/provider-settings/${encodeURIComponent(provider.providerID)}/connect`,
          {
            method: "POST",
            body: requestBody,
          },
        );
        replaceProvider(updated);
        renderHomeProviders();
        renderRoute();
        toast(`${provider.displayName} connection stored; test it before use`);
        announce(`${provider.displayName} connection stored`);
      } catch (error) {
        message.textContent = `${error.message} Credential fields were cleared; enter the value again to retry.`;
        message.className = "inline-message error form-message";
        message.focus({ preventScroll: true });
        form
          .querySelectorAll("input, select, button")
          .forEach((control) => setDisabledReason(control, false, ""));
        submit.textContent = originalLabel;
        toast(error.message, true);
      } finally {
        disposeSensitiveInputs(form);
        if (Object.hasOwn(payload, "credential")) payload.credential = null;
        if (Object.hasOwn(payload, "keyHelperCommand"))
          payload.keyHelperCommand = null;
        requestBody = "";
        form.removeAttribute("aria-busy");
      }
    });

    wrapper.append(form);
    return wrapper;
  }

  async function startAuthFlow(provider, flow, button, message) {
    const originalLabel = button.textContent;
    button.textContent = "Starting…";
    setDisabledReason(button, true, "Authentication flow is starting.");
    message.textContent = "Requesting a transient authentication challenge…";
    try {
      const status = await api(
        `api/v1/provider-settings/${encodeURIComponent(provider.providerID)}/auth-flows`,
        {
          method: "POST",
          body: JSON.stringify({ kind: flow.kind }),
        },
      );
      state.activeFlow = {
        ...status,
        providerID: status.providerID || provider.providerID,
        error: null,
      };
      renderRoute();
      scheduleFlowPoll();
      toast(`${flow.displayName} started`);
      announce(`${flow.displayName} started`);
    } catch (error) {
      message.textContent = error.message;
      message.className = "inline-message error";
      message.focus({ preventScroll: true });
      button.textContent = originalLabel;
      setDisabledReason(button, false, "");
      toast(error.message, true);
    }
  }

  function devicePanel(provider) {
    const flow = state.activeFlow;
    const panel = element("section", "device-panel");
    panel.dataset.flowState = flow.state;
    const header = element("div", "device-panel-header");
    const copy = element("div");
    copy.append(
      element(
        "h4",
        "",
        authenticationMethodName(
          provider,
          flow.kind,
          authFlowForMethod(provider.capabilities.authFlows || [], flow.kind),
        ),
      ),
      element("p", "", flow.detail || "Waiting for provider authorization."),
    );
    header.append(copy);
    panel.append(header);
    if (flow.userCode)
      panel.append(element("code", "device-code", flow.userCode));
    if (flow.verificationURL) {
      const verification = element(
        "a",
        "secondary-button verification-link",
        "Open Verification Page",
      );
      verification.href = flow.verificationURL;
      verification.target = "_blank";
      verification.rel = "noopener noreferrer";
      verification.append(iconNode("link"));
      panel.append(verification);
    }
    panel.append(element("p", "", `Expires ${formatDate(flow.expiresAt)}`));
    if (flow.error) {
      const error = element("div", "inline-message error", flow.error);
      error.setAttribute("role", "alert");
      panel.append(error);
    }
    const status = element("span", "polling-status");
    status.append(
      element("i"),
      document.createTextNode(
        state.pollPromise ? "Checking provider…" : "Waiting for authorization",
      ),
    );
    const actions = element("div", "flow-actions");
    const poll = element("button", "secondary-button", "Check Now");
    poll.type = "button";
    poll.dataset.action = "poll-auth-flow";
    setDisabledReason(
      poll,
      Boolean(state.pollPromise),
      "A provider status check is already in progress.",
    );
    if (!poll.disabled)
      poll.addEventListener("click", () => pollActiveFlow(true));
    const cancel = element(
      "button",
      "danger-button subtle",
      "Cancel Authentication",
    );
    cancel.type = "button";
    cancel.dataset.action = "cancel-auth-flow";
    setDisabledReason(
      cancel,
      Boolean(state.pollPromise),
      "Wait for the current provider status check to finish.",
    );
    if (!cancel.disabled)
      cancel.addEventListener("click", () =>
        cancelActiveFlow(provider, cancel),
      );
    actions.append(poll, cancel);
    panel.append(status, actions);
    return panel;
  }

  function refreshActiveFlowPanel() {
    if (!state.activeFlow) return;
    const provider = state.providers.find(
      (item) => item.providerID === state.activeFlow.providerID,
    );
    const card = [...document.querySelectorAll("[data-provider-id]")].find(
      (item) => item.dataset.providerId === state.activeFlow.providerID,
    );
    const current = card?.querySelector(".device-panel");
    if (!provider || !current) return;
    current.replaceWith(devicePanel(provider));
    installIcons(card);
  }

  function clearPollTimer() {
    if (state.pollTimer !== null) {
      window.clearTimeout(state.pollTimer);
      state.pollTimer = null;
    }
  }

  function scheduleFlowPoll() {
    clearPollTimer();
    if (!state.activeFlow || state.activeFlow.state !== "pending") return;
    state.pollTimer = window.setTimeout(() => {
      state.pollTimer = null;
      pollActiveFlow(false);
    }, pollDelay);
  }

  async function pollActiveFlow(manual = false) {
    if (!state.activeFlow || state.pollPromise) return state.pollPromise;
    const flowID = state.activeFlow.flowID;
    clearPollTimer();
    state.pollPromise = (async () => {
      try {
        const status = await api(
          `api/v1/provider-auth-flows/${encodeURIComponent(flowID)}`,
        );
        if (!state.activeFlow || state.activeFlow.flowID !== flowID) return;
        state.activeFlow = {
          ...status,
          providerID: status.providerID || state.activeFlow.providerID,
          error: null,
        };
        if (terminalFlowStates.has(status.state)) {
          const terminal = status.state;
          const detail = status.detail || `Authentication ${terminal}.`;
          state.activeFlow.userCode = null;
          state.activeFlow.verificationURL = null;
          clearPollTimer();
          if (terminal === "completed") {
            state.activeFlow = null;
            toast("Authentication completed");
            announce("Authentication completed");
            await loadAll(true);
          } else {
            state.activeFlow = null;
            renderRoute();
            toast(detail, terminal === "failed");
            announce(detail);
          }
        } else {
          scheduleFlowPoll();
          if (manual) announce("Authentication is still pending");
        }
      } catch (error) {
        if (state.activeFlow?.flowID === flowID) {
          state.activeFlow.error = `${error.message} Automatic polling will retry.`;
          scheduleFlowPoll();
        }
        toast(error.message, true);
      } finally {
        state.pollPromise = null;
        if (state.activeFlow?.flowID === flowID) refreshActiveFlowPanel();
      }
    })();
    refreshActiveFlowPanel();
    return state.pollPromise;
  }

  async function cancelActiveFlow(provider, button) {
    if (!state.activeFlow) return;
    const flowID = state.activeFlow.flowID;
    clearPollTimer();
    button.textContent = "Cancelling…";
    setDisabledReason(
      button,
      true,
      "Authentication cancellation is in progress.",
    );
    try {
      await api(`api/v1/provider-auth-flows/${encodeURIComponent(flowID)}`, {
        method: "DELETE",
        body: "{}",
      });
      if (state.activeFlow?.flowID === flowID) state.activeFlow = null;
      renderRoute();
      toast(`${provider.displayName} authentication cancelled`);
      announce(`${provider.displayName} authentication cancelled`);
    } catch (error) {
      if (state.activeFlow?.flowID === flowID)
        state.activeFlow.error = error.message;
      renderRoute();
      toast(error.message, true);
      scheduleFlowPoll();
    }
  }

  function renderPageError(error) {
    const content = document.getElementById("settings-content");
    disposeSensitiveInputs(content);
    const panel = element("div", "error-banner");
    panel.setAttribute("role", "alert");
    panel.append(iconNode("warning"), document.createTextNode(error.message));
    content.replaceChildren(panel);
    installIcons(content);
  }

  function confirmAction({ title, message, label, returnFocus }) {
    if (state.confirmResolver) state.confirmResolver(false);
    const backdrop = document.getElementById("confirm-dialog");
    document.getElementById("confirm-title").textContent = title;
    document.getElementById("confirm-message").textContent = message;
    document.getElementById("confirm-action-button").textContent = label;
    state.confirmReturnFocus = returnFocus || document.activeElement;
    backdrop.hidden = false;
    const dialog = backdrop.querySelector('[role="dialog"]');
    window.setTimeout(() => dialog.focus({ preventScroll: true }), 0);
    return new Promise((resolve) => {
      state.confirmResolver = resolve;
    });
  }

  function closeConfirm(accepted) {
    if (!state.confirmResolver) return;
    const resolve = state.confirmResolver;
    const returnFocus = state.confirmReturnFocus;
    state.confirmResolver = null;
    state.confirmReturnFocus = null;
    document.getElementById("confirm-dialog").hidden = true;
    resolve(accepted);
    if (!accepted && returnFocus?.isConnected)
      returnFocus.focus({ preventScroll: true });
  }

  function trapDialogFocus(event) {
    const backdrop = document.getElementById("confirm-dialog");
    if (backdrop.hidden || event.key !== "Tab") return;
    const focusable = [
      ...backdrop.querySelectorAll(
        'button:not(:disabled), [href], [tabindex]:not([tabindex="-1"])',
      ),
    ];
    if (!focusable.length) return;
    const first = focusable[0];
    const last = focusable[focusable.length - 1];
    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault();
      last.focus();
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault();
      first.focus();
    }
  }

  function filterSettingsNavigation(query) {
    const normalized = query.trim().toLowerCase();
    let visibleCount = 0;
    document.querySelectorAll("[data-settings-section]").forEach((section) => {
      let sectionCount = 0;
      section.querySelectorAll("a, .unavailable-nav-row").forEach((row) => {
        const label = (
          row.dataset.searchLabel || row.textContent
        ).toLowerCase();
        const visible = !normalized || label.includes(normalized);
        row.hidden = !visible;
        if (visible) sectionCount += 1;
      });
      section.hidden = sectionCount === 0;
      visibleCount += sectionCount;
    });
    document.getElementById("settings-no-results").hidden = visibleCount > 0;
    document.getElementById("clear-settings-search").hidden = !normalized;
    document.getElementById("settings-search-status").textContent = normalized
      ? visibleCount
        ? `${visibleCount} setting${visibleCount === 1 ? "" : "s"} found.`
        : "No settings found."
      : "";
  }

  function visibleSettingsLinks() {
    return [...document.querySelectorAll("#settings-nav a[data-route]")].filter(
      (link) => !link.hidden && !link.closest("section")?.hidden,
    );
  }

  function openSettingsDrawer() {
    if (!window.matchMedia("(max-width: 720px)").matches) return;
    const shell = document.getElementById("settings-shell");
    const sidebar = document.getElementById("settings-sidebar");
    const toggle = document.getElementById("settings-drawer-toggle");
    state.settingsDrawerReturnFocus = document.activeElement;
    shell.classList.add("drawer-open");
    document.getElementById("settings-drawer-backdrop").hidden = false;
    toggle.setAttribute("aria-expanded", "true");
    toggle.setAttribute("aria-label", "Close settings navigation");
    sidebar.setAttribute("aria-modal", "true");
    window.setTimeout(
      () => document.getElementById("settings-search").focus(),
      0,
    );
  }

  function closeSettingsDrawer({ restoreFocus = true } = {}) {
    const shell = document.getElementById("settings-shell");
    if (!shell.classList.contains("drawer-open")) return;
    shell.classList.remove("drawer-open");
    document.getElementById("settings-drawer-backdrop").hidden = true;
    const toggle = document.getElementById("settings-drawer-toggle");
    toggle.setAttribute("aria-expanded", "false");
    toggle.setAttribute("aria-label", "Open settings navigation");
    document.getElementById("settings-sidebar").removeAttribute("aria-modal");
    const returnFocus = state.settingsDrawerReturnFocus;
    state.settingsDrawerReturnFocus = null;
    if (restoreFocus && returnFocus?.isConnected)
      returnFocus.focus({ preventScroll: true });
  }

  function clearSettingsSearch(focus = true) {
    const input = document.getElementById("settings-search");
    input.value = "";
    filterSettingsNavigation("");
    if (focus) input.focus({ preventScroll: true });
  }

  function handleDocumentClick(event) {
    const routeLink = event.target.closest("[data-route-link]");
    if (routeLink) {
      state.focusAfterRoute = true;
      if (routeLink.closest("#settings-sidebar"))
        closeSettingsDrawer({ restoreFocus: false });
      if (routeLink.hash === location.hash) window.setTimeout(renderRoute, 0);
    }
    const action = event.target.closest("[data-action]")?.dataset.action;
    if (action === "refresh") loadAll(true);
    else if (action === "new-chat") beginNewSession();
    else if (action === "load-earlier") {
      const earliest = state.agent.transcriptItems[0]?.sessionSequence;
      if (earliest) loadTranscript({ before: earliest });
    } else if (action === "clear-session-search") {
      state.agent.searchText = "";
      document.getElementById("session-search").value = "";
      document.getElementById("clear-session-search").hidden = true;
      renderSessions();
      document.getElementById("session-search").focus({ preventScroll: true });
    } else if (action === "skip-content") {
      const target = document.getElementById("settings-shell").hidden
        ? document.getElementById("main-content")
        : document.getElementById("settings-main-content");
      target.focus({ preventScroll: true });
    } else if (action === "clear-settings-search") clearSettingsSearch();
    else if (action === "toggle-settings-drawer") {
      if (
        document
          .getElementById("settings-shell")
          .classList.contains("drawer-open")
      )
        closeSettingsDrawer();
      else openSettingsDrawer();
    } else if (action === "close-settings-drawer") closeSettingsDrawer();
    else if (action === "cancel-confirm") closeConfirm(false);
    else if (action === "accept-confirm") closeConfirm(true);
  }

  function handleDocumentKeydown(event) {
    trapDialogFocus(event);
    const drawerOpen = document
      .getElementById("settings-shell")
      .classList.contains("drawer-open");
    if (drawerOpen && event.key === "Tab") {
      const focusable = [
        ...document
          .getElementById("settings-sidebar")
          .querySelectorAll(
            "input:not(:disabled), button:not(:disabled):not([hidden]), a[href]:not([hidden])",
          ),
      ].filter((node) => !node.closest("[hidden]"));
      const first = focusable[0];
      const last = focusable.at(-1);
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last?.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first?.focus();
      }
    }
    if (event.key !== "Escape") return;
    if (!document.getElementById("confirm-dialog").hidden) {
      event.preventDefault();
      closeConfirm(false);
      return;
    }
    if (drawerOpen) {
      event.preventDefault();
      closeSettingsDrawer();
      return;
    }
    if (
      document.activeElement === document.getElementById("settings-search") &&
      document.getElementById("settings-search").value
    ) {
      event.preventDefault();
      clearSettingsSearch();
    } else if (
      document.activeElement === document.getElementById("session-search") &&
      document.getElementById("session-search").value
    ) {
      event.preventDefault();
      state.agent.searchText = "";
      document.getElementById("session-search").value = "";
      document.getElementById("clear-session-search").hidden = true;
      renderSessions();
    }
  }

  function start() {
    if (state.initialized) return;
    state.initialized = true;
    applyPortalAppearance();
    installIcons();
    renderInitialLoading();
    document.addEventListener("click", handleDocumentClick);
    document.addEventListener("keydown", handleDocumentKeydown);
    document
      .getElementById("settings-search")
      .addEventListener("input", (event) => {
        filterSettingsNavigation(event.target.value);
      });
    document
      .getElementById("settings-search")
      .addEventListener("keydown", (event) => {
        const links = visibleSettingsLinks();
        if ((event.key === "ArrowDown" || event.key === "Enter") && links[0]) {
          event.preventDefault();
          if (event.key === "Enter") links[0].click();
          else links[0].focus({ preventScroll: true });
        }
      });
    document
      .getElementById("settings-nav")
      .addEventListener("keydown", (event) => {
        if (!["ArrowDown", "ArrowUp", "Home", "End"].includes(event.key))
          return;
        const links = visibleSettingsLinks();
        const current = links.indexOf(document.activeElement);
        if (current < 0) return;
        event.preventDefault();
        const next =
          event.key === "Home"
            ? 0
            : event.key === "End"
              ? links.length - 1
              : event.key === "ArrowDown"
                ? Math.min(links.length - 1, current + 1)
                : Math.max(0, current - 1);
        links[next]?.focus({ preventScroll: true });
      });
    document
      .getElementById("session-search")
      .addEventListener("input", (event) => {
        state.agent.searchText = event.target.value;
        document.getElementById("clear-session-search").hidden =
          !event.target.value;
        renderSessions();
      });
    document
      .getElementById("composer-provider")
      .addEventListener("change", () => {
        state.agent.retryOperation = null;
        renderAgentComposer();
      });
    document.getElementById("composer-model").addEventListener("change", () => {
      state.agent.retryOperation = null;
    });
    document.getElementById("composer-text").addEventListener("input", () => {
      state.agent.retryOperation = null;
      renderAgentComposer();
    });
    document
      .getElementById("composer-form")
      .addEventListener("submit", (event) => {
        event.preventDefault();
        submitComposer();
      });
    document.addEventListener("visibilitychange", () => {
      if (document.hidden) clearAgentPoll();
      else scheduleAgentPoll();
    });
    window.addEventListener("hashchange", renderRoute);
    window.addEventListener("offline", () => {
      setConnectionPresentation(
        "offline",
        "This browser is offline. Changes require a restored connection.",
      );
      document.getElementById("service-caption").textContent =
        "Browser offline";
      announce("Browser is offline");
    });
    window.addEventListener("online", () => {
      setConnectionPresentation(
        "stale",
        "Connection restored. Refreshing server state…",
      );
      loadAll(true);
    });
    window.addEventListener("pagehide", () => {
      disposeSensitiveInputs();
      clearPollTimer();
      clearAgentPoll();
    });
    renderRoute();
    ensureOperatorSession().then((ready) => {
      if (ready) loadAll(false);
    });
  }

  async function ensureOperatorSession() {
    const gate = document.getElementById("auth-gate");
    const form = document.getElementById("auth-form");
    const error = document.getElementById("auth-error");
    let status;
    try {
      status = await api("api/v1/auth/status");
    } catch (failure) {
      gate.hidden = true;
      return true;
    }
    if (status.authenticated) {
      gate.hidden = true;
      return true;
    }
    gate.hidden = false;
    if (!status.passwordLoginEnabled) {
      document.getElementById("auth-title").textContent = "Operator certificate required";
      document.getElementById("auth-copy").textContent =
        "This server uses mutual TLS. Import the operator client certificate in your browser, then reload.";
      form.hidden = true;
      return false;
    }
    form.hidden = false;
    const setup = !!status.needsSetup;
    document.getElementById("auth-title").textContent = setup
      ? "Create the operator password"
      : "Sign in";
    document.getElementById("auth-copy").textContent = setup
      ? "This is the first launch. Choose a password for the operator account. If you are not on this machine, paste the setup token printed in the server log."
      : "Enter the operator password to open the portal.";
    document.getElementById("auth-token-field").hidden = !setup;
    document.getElementById("auth-confirm-field").hidden = !setup;
    document.getElementById("auth-password").autocomplete = setup
      ? "new-password"
      : "current-password";
    document.getElementById("auth-submit").textContent = setup
      ? "Create password"
      : "Sign in";
    return await new Promise((resolve) => {
      form.addEventListener("submit", async (event) => {
        event.preventDefault();
        error.hidden = true;
        const password = document.getElementById("auth-password").value;
        try {
          if (setup) {
            const confirmation = document.getElementById(
              "auth-password-confirm",
            ).value;
            await api("api/v1/setup", {
              method: "POST",
              body: JSON.stringify({
                password,
                passwordConfirmation: confirmation,
                setupToken: document.getElementById("auth-token").value.trim(),
              }),
            });
          } else {
            await api("api/v1/login", {
              method: "POST",
              body: JSON.stringify({ password }),
            });
          }
          gate.hidden = true;
          resolve(true);
        } catch (failure) {
          error.hidden = false;
          error.textContent = failure.message;
        }
      });
    });
  }

  if (window.__REPOPROMPT_PORTAL_TEST_HOOK__) {
    window.RepoPromptPortalTest = Object.freeze({
      state,
      start,
      loadAll,
      renderRoute,
      pollActiveFlow,
      loadTranscript,
      selectSession,
      beginNewSession,
      submitComposer,
      disposeSensitiveInputs,
      whenIdle: async () => {
        await state.loadPromise;
        await state.settingsMutation;
        await Promise.all(Object.values(state.domainMutations).filter(Boolean));
        await state.agent.transcriptPromise;
        await state.agent.mutationPromise;
      },
    });
  }

  start();
})();
