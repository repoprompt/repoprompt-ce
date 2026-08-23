"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const portalRoot = path.resolve(
  __dirname,
  "../../Sources/RepoPromptServiceHTTP/Resources/Portal",
);
const portalScriptPath = path.join(portalRoot, "portal.js");
const portalHTMLPath = path.join(portalRoot, "index.html");
const portalScript = fs.readFileSync(portalScriptPath, "utf8");
const portalHTML = fs.readFileSync(portalHTMLPath, "utf8");

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, reject, resolve };
}

function response(body, status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    headers: {
      get(name) {
        return name.toLowerCase() === "content-type"
          ? "application/json"
          : "";
      },
    },
    async text() {
      return status === 204 ? "" : JSON.stringify(body);
    },
  };
}

async function nextTurn() {
  await new Promise((resolve) => setImmediate(resolve));
}

async function eventually(predicate, message, turns = 200) {
  for (let attempt = 0; attempt < turns; attempt += 1) {
    if (predicate()) return;
    await nextTurn();
  }
  assert.fail(message);
}

function dataName(name) {
  return name.replace(/^data-/, "").replace(/-([a-z])/g, (_, letter) =>
    letter.toUpperCase(),
  );
}

class FakeClassList {
  constructor(node) {
    this.node = node;
  }

  add(...names) {
    names.forEach((name) => this.node.classes.add(name));
  }

  remove(...names) {
    names.forEach((name) => this.node.classes.delete(name));
  }

  contains(name) {
    return this.node.classes.has(name);
  }

  toggle(name, force) {
    if (force === true) {
      this.node.classes.add(name);
      return true;
    }
    if (force === false) {
      this.node.classes.delete(name);
      return false;
    }
    if (this.node.classes.has(name)) {
      this.node.classes.delete(name);
      return false;
    }
    this.node.classes.add(name);
    return true;
  }
}

class FakeNode {
  constructor(document, tagName = "div", options = {}) {
    this.ownerDocument = document;
    this.tagName = tagName.toUpperCase();
    this.id = options.id || "";
    this.parentNode = null;
    this.children = [];
    this.listeners = new Map();
    this.attributes = new Map();
    this.dataset = {};
    this.classes = new Set();
    this.classList = new FakeClassList(this);
    this.style = {
      setProperty() {},
      removeProperty() {},
    };
    this.hidden = options.hidden === true;
    this.inert = false;
    this.disabled = false;
    this.checked = false;
    this.required = false;
    this.selected = false;
    this.value = options.value || "";
    this.textContent = options.textContent || "";
    this.type = options.type || "";
    this.name = options.name || "";
    this.autocomplete = "";
    this.title = "";
    this.href = "";
    this.hash = "";
    this.isConnected = options.isConnected === true;
    this.tabIndex = 0;
    this.scrollTop = 0;
    this.scrollHeight = 0;
    this.clientHeight = 0;
    if (options.className) this.className = options.className;
    for (const [name, value] of Object.entries(options.attributes || {})) {
      this.setAttribute(name, value);
    }
  }

  get className() {
    return [...this.classes].join(" ");
  }

  set className(value) {
    this.classes = new Set(String(value || "").split(/\s+/).filter(Boolean));
  }

  get parentElement() {
    return this.parentNode;
  }

  get firstChild() {
    return this.children[0] || null;
  }

  get lastChild() {
    return this.children.at(-1) || null;
  }

  addEventListener(name, listener) {
    const listeners = this.listeners.get(name) || [];
    listeners.push(listener);
    this.listeners.set(name, listeners);
  }

  dispatch(name, overrides = {}) {
    const event = {
      target: this,
      currentTarget: this,
      key: "",
      shiftKey: false,
      defaultPrevented: false,
      preventDefault() {
        this.defaultPrevented = true;
      },
      stopPropagation() {},
      ...overrides,
    };
    return (this.listeners.get(name) || []).map((listener) => listener(event));
  }

  click() {
    return this.dispatch("click");
  }

  focus() {
    this.ownerDocument.activeElement = this;
  }

  blur() {
    if (this.ownerDocument.activeElement === this) {
      this.ownerDocument.activeElement = null;
    }
  }

  append(...values) {
    values.flat().forEach((value) => this.appendChild(value));
  }

  prepend(...values) {
    const nodes = values.flat().map((value) => this.asNode(value));
    nodes.reverse().forEach((node) => {
      this.detach(node);
      node.parentNode = this;
      this.children.unshift(node);
      node.setConnected(this.isConnected);
    });
  }

  appendChild(value) {
    const node = this.asNode(value);
    this.detach(node);
    node.parentNode = this;
    this.children.push(node);
    node.setConnected(this.isConnected);
    return node;
  }

  replaceChildren(...values) {
    this.children.forEach((child) => {
      child.parentNode = null;
      child.setConnected(false);
    });
    this.children = [];
    this.append(...values);
  }

  remove() {
    if (!this.parentNode) return;
    const siblings = this.parentNode.children;
    const index = siblings.indexOf(this);
    if (index >= 0) siblings.splice(index, 1);
    this.parentNode = null;
    this.setConnected(false);
  }

  setConnected(value) {
    this.isConnected = value;
    this.children.forEach((child) => child.setConnected(value));
  }

  asNode(value) {
    if (value instanceof FakeNode) return value;
    return new FakeNode(this.ownerDocument, "#text", {
      isConnected: this.isConnected,
      textContent: String(value),
    });
  }

  detach(node) {
    if (node.parentNode) node.remove();
  }

  setAttribute(name, value) {
    const normalized = String(value);
    this.attributes.set(name, normalized);
    if (name === "id") this.id = normalized;
    else if (name === "class") this.className = normalized;
    else if (name === "hidden") this.hidden = true;
    else if (name === "value") this.value = normalized;
    else if (name === "name") this.name = normalized;
    else if (name === "href") {
      this.href = normalized;
      this.hash = normalized.startsWith("#") ? normalized : "";
    } else if (name.startsWith("data-")) {
      this.dataset[dataName(name)] = normalized;
    }
  }

  getAttribute(name) {
    return this.attributes.get(name) ?? null;
  }

  hasAttribute(name) {
    return this.attributes.has(name);
  }

  removeAttribute(name) {
    this.attributes.delete(name);
    if (name === "hidden") this.hidden = false;
    else if (name === "class") this.classes.clear();
    else if (name.startsWith("data-")) delete this.dataset[dataName(name)];
  }

  toggleAttribute(name, force) {
    const next = force === undefined ? !this.hasAttribute(name) : force;
    if (next) this.setAttribute(name, "");
    else this.removeAttribute(name);
    return next;
  }

  insertAdjacentHTML() {}

  scrollIntoView() {}

  setSelectionRange() {}

  reset() {
    this.querySelectorAll("input").forEach((input) => {
      input.value = "";
    });
  }

  matches(selector) {
    const value = selector.trim();
    if (!value) return false;
    if (value === "[hidden]") return this.hidden;
    if (value === "[data-action]") return this.dataset.action !== undefined;
    if (value === "[data-route-link]")
      return this.dataset.routeLink !== undefined;
    if (value === "[data-settings-section]")
      return this.dataset.settingsSection !== undefined;
    if (value === "input[data-sensitive]")
      return this.tagName === "INPUT" && this.dataset.sensitive !== undefined;
    if (value === "input[name]") return this.tagName === "INPUT" && !!this.name;
    if (value === "a[href]") return this.tagName === "A" && !!this.href;
    if (value.startsWith("#")) return this.id === value.slice(1);
    if (value.startsWith(".")) return this.classList.contains(value.slice(1));
    const tag = value.match(/^[a-z]+/i)?.[0];
    if (tag && this.tagName !== tag.toUpperCase()) return false;
    if (value.includes(":not(:disabled)") && this.disabled) return false;
    if (value.includes(":disabled") && !value.includes(":not(:disabled)") && !this.disabled)
      return false;
    if (value.includes(":not([hidden])") && this.hidden) return false;
    return !!tag;
  }

  querySelectorAll(selector) {
    if (this.id === "auth-form" && selector === "input[data-sensitive]") {
      return ["auth-token", "auth-password", "auth-password-confirm"].map((id) =>
        this.ownerDocument.getElementById(id),
      );
    }
    const selectors = selector.split(",").map((value) => value.trim());
    const matches = [];
    const visit = (node) => {
      node.children.forEach((child) => {
        if (selectors.some((candidate) => child.matches(candidate))) {
          matches.push(child);
        }
        visit(child);
      });
    };
    visit(this);
    return matches;
  }

  querySelector(selector) {
    return this.querySelectorAll(selector)[0] || null;
  }

  closest(selector) {
    let node = this;
    while (node) {
      if (node.matches(selector)) return node;
      node = node.parentNode;
    }
    return null;
  }
}

class FakeDocument {
  constructor(html) {
    this.nodes = new Map();
    this.createdNodes = [];
    this.listeners = new Map();
    this.activeElement = null;
    this.hidden = false;
    this.cookie = "";
    this.documentElement = this.createStaticNode("html", "document-element");
    this.body = this.createStaticNode("body", "body");
    const pattern = /<([a-z][\w-]*)([^>]*\sid="([^"]+)"[^>]*)>/gi;
    for (const match of html.matchAll(pattern)) {
      const [, tagName, attributes, id] = match;
      const attributeMap = {};
      for (const attribute of attributes.matchAll(/([\w-]+)(?:="([^"]*)")?/g)) {
        attributeMap[attribute[1]] = attribute[2] ?? "";
      }
      const node = this.createStaticNode(tagName, id, {
        hidden: Object.hasOwn(attributeMap, "hidden"),
        type: attributeMap.type,
        value: attributeMap.value,
      });
      for (const [name, value] of Object.entries(attributeMap)) {
        node.setAttribute(name, value);
      }
    }
    ["auth-token", "auth-password", "auth-password-confirm"].forEach((id) => {
      this.getElementById(id).dataset.sensitive = "true";
    });
  }

  createStaticNode(tagName, id, options = {}) {
    const node = new FakeNode(this, tagName, {
      ...options,
      id,
      isConnected: true,
    });
    this.nodes.set(id, node);
    this.createdNodes.push(node);
    return node;
  }

  createElement(tagName) {
    const node = new FakeNode(this, tagName);
    this.createdNodes.push(node);
    return node;
  }

  createTextNode(text) {
    const node = new FakeNode(this, "#text", { textContent: text });
    this.createdNodes.push(node);
    return node;
  }

  getElementById(id) {
    return this.nodes.get(id) || null;
  }

  addEventListener(name, listener) {
    const listeners = this.listeners.get(name) || [];
    listeners.push(listener);
    this.listeners.set(name, listeners);
  }

  dispatch(name, overrides = {}) {
    const event = {
      target: this,
      preventDefault() {},
      stopPropagation() {},
      ...overrides,
    };
    return (this.listeners.get(name) || []).map((listener) => listener(event));
  }

  querySelectorAll(selector) {
    if (selector === "#settings-nav a[data-route]") return [];
    if (selector === "[data-settings-section]") return [];
    const selectors = selector.split(",").map((value) => value.trim());
    return this.createdNodes.filter(
      (node) =>
        node.isConnected && selectors.some((candidate) => node.matches(candidate)),
    );
  }

  querySelector(selector) {
    return this.querySelectorAll(selector)[0] || null;
  }
}

class FakePortalServer {
  constructor({ authenticated, needsSetup }) {
    this.authenticated = authenticated;
    this.needsSetup = needsSetup;
    this.requests = [];
    this.routes = [];
    this.bootstrapVersion = 0;
  }

  enqueue(predicate, handler) {
    this.routes.push({ handler, predicate });
  }

  count(pathname, method = null) {
    return this.requests.filter(
      (request) =>
        request.path === pathname && (!method || request.method === method),
    ).length;
  }

  async fetch(pathname, options = {}) {
    const method = (options.method || "GET").toUpperCase();
    const request = { method, options, path: String(pathname) };
    this.requests.push(request);
    const routeIndex = this.routes.findIndex((route) => route.predicate(request));
    if (routeIndex >= 0) {
      const [route] = this.routes.splice(routeIndex, 1);
      return route.handler(request);
    }
    return this.defaultResponse(request);
  }

  defaultResponse(request) {
    const pathname = request.path;
    if (pathname === "api/v1/auth/status") {
      return response({
        authenticated: this.authenticated,
        needsSetup: this.needsSetup,
        passwordLoginEnabled: true,
      });
    }
    if (pathname === "api/v1/setup" && request.method === "POST") {
      this.authenticated = true;
      this.needsSetup = false;
      return response({});
    }
    if (pathname === "api/v1/login" && request.method === "POST") {
      this.authenticated = true;
      return response({});
    }
    if (pathname === "api/v1/logout" && request.method === "POST") {
      this.authenticated = false;
      return response(null, 204);
    }
    if (pathname === "api/v1/bootstrap") {
      this.bootstrapVersion += 1;
      return response({
        marker: `bootstrap-${this.bootstrapVersion}`,
        projects: [],
        sessions: [],
        workflows: [],
      });
    }
    if (pathname.startsWith("api/v1/provider-settings")) {
      return response({
        generatedAt: "2026-08-21T00:00:00Z",
        providers: [
          {
            providerID: "codex",
            displayName: "Codex",
            category: "cli",
            summary: "Codex CLI",
            deploymentAllowed: true,
            cli: { installed: true },
            capabilities: {
              authenticationMethods: ["deviceCodeBeta", "browserOAuth"],
              authFlows: [
                {
                  kind: "deviceCodeBeta",
                  displayName: "Device code",
                  startable: true,
                },
                {
                  kind: "browserOAuth",
                  displayName: "Browser login",
                  startable: true,
                },
              ],
            },
            models: [],
          },
          {
            providerID: "cursorACP",
            displayName: "Cursor",
            category: "cli",
            summary: "Cursor CLI",
            deploymentAllowed: true,
            cli: { installed: true },
            capabilities: {
              authenticationMethods: ["browserLogin"],
              authFlows: [],
            },
            models: [],
          },
          {
            providerID: "openCodeACP",
            displayName: "OpenCode",
            category: "cli",
            summary: "OpenCode CLI",
            deploymentAllowed: true,
            cli: { installed: true },
            capabilities: {
              authenticationMethods: ["providerSpecific"],
              authFlows: [],
            },
            models: [],
          },
        ],
      });
    }
    if (pathname === "api/v1/account/sessions") return response([]);
    if (pathname === "api/v1/operations") return response({});
    if (pathname === "api/v1/workflows") {
      return response({ revision: 1, workflows: [] });
    }
    return response({});
  }
}

function createWindow(document, server, location) {
  const listeners = new Map();
  let nextTimer = 1;
  const window = {
    __REPOPROMPT_PORTAL_TEST_HOOK__: { deferStart: true },
    addEventListener(name, listener) {
      const values = listeners.get(name) || [];
      values.push(listener);
      listeners.set(name, values);
    },
    clearTimeout() {},
    close() {},
    innerWidth: 1280,
    matchMedia() {
      return {
        matches: false,
        addEventListener() {},
        removeEventListener() {},
      };
    },
    open() {},
    setTimeout() {
      const timer = nextTimer;
      nextTimer += 1;
      return timer;
    },
  };
  window.window = window;
  window.document = document;
  window.location = location;
  window.navigator = {
    onLine: true,
    clipboard: { async writeText() {} },
  };
  window.fetch = server.fetch.bind(server);
  return window;
}

function createHarness(options) {
  const document = new FakeDocument(portalHTML);
  const location = { hash: options.hash || "#settings/operator-account" };
  const server = new FakePortalServer(options);
  const window = createWindow(document, server, location);
  const context = {
    AbortController,
    Blob,
    CSS: { escape: (value) => String(value) },
    URL,
    clearTimeout: window.clearTimeout,
    console,
    crypto: { randomUUID: () => "00000000-0000-4000-8000-000000000001" },
    document,
    encodeURIComponent,
    fetch: window.fetch,
    location,
    navigator: window.navigator,
    setTimeout: window.setTimeout,
    structuredClone,
    window,
  };
  vm.runInNewContext(portalScript, context, { filename: portalScriptPath });
  assert.ok(window.RepoPromptPortalTest, "production IIFE should expose the inert test hook");
  return {
    context,
    document,
    hook: window.RepoPromptPortalTest,
    location,
    server,
    window,
  };
}

function descendants(root) {
  const values = [];
  const visit = (node) => {
    node.children.forEach((child) => {
      values.push(child);
      visit(child);
    });
  };
  visit(root);
  return values;
}

function buttonWithText(document, text) {
  return descendants(document.getElementById("settings-content")).find(
    (node) => node.tagName === "BUTTON" && node.textContent === text,
  );
}

async function startAndWaitForLoad(harness) {
  harness.hook.start();
  await eventually(
    () =>
      harness.hook.state.operatorAuthenticated &&
      harness.hook.state.bootstrap?.marker &&
      harness.hook.state.loadOperation === null,
    "production startup should authenticate and complete loadAll",
  );
}

async function submitAuthentication(harness, password) {
  harness.document.getElementById("auth-password").value = password;
  harness.document.getElementById("auth-form").dispatch("submit");
  await eventually(
    () => harness.hook.state.operatorAuthenticated,
    "production authentication form should activate the portal",
  );
  await eventually(
    () =>
      harness.hook.state.bootstrap?.marker &&
      harness.hook.state.loadOperation === null,
    "production authentication should start and complete a new loadAll",
  );
}

test("production IIFE: initially authenticated logout exposes a functional login submit", async () => {
  const harness = createHarness({ authenticated: true, needsSetup: false });
  await startAndWaitForLoad(harness);

  assert.equal(harness.document.getElementById("app").hidden, false);
  const logout = buttonWithText(harness.document, "Logout");
  assert.ok(logout, "authenticated Account surface should render Logout");
  harness.document.getElementById("auth-token").value = "stale-setup-token";
  harness.document.getElementById("auth-password").value = "stale-password";
  harness.document.getElementById("auth-password-confirm").value = "stale-confirmation";
  logout.click();
  await eventually(
    () => !harness.hook.state.operatorAuthenticated && !harness.hook.state.logoutPromise,
    "visible Logout should run production logoutOperator and reset the portal",
  );

  assert.equal(harness.hook.state.authenticationMode, "login");
  assert.equal(harness.document.getElementById("auth-form").hidden, false);
  assert.equal(harness.document.getElementById("settings-content").children.length, 0);
  for (const id of ["auth-token", "auth-password", "auth-password-confirm"]) {
    assert.equal(harness.document.getElementById(id).value, "");
  }
  const logoutRequest = harness.server.requests.find(
    (request) => request.path === "api/v1/logout",
  );
  assert.equal(logoutRequest.options.headers["X-RepoPrompt-Portal-CSRF"], "1");
  await submitAuthentication(harness, "operator-password");

  assert.equal(harness.server.count("api/v1/auth/status", "GET"), 1);
  assert.equal(harness.server.count("api/v1/login", "POST"), 1);
  assert.equal(harness.server.count("api/v1/setup", "POST"), 0);
  assert.equal(harness.document.getElementById("app").hidden, false);
  assert.equal(harness.document.getElementById("auth-gate").hidden, true);
});

test("production IIFE: failed logout still clears the authenticated terminal state", async () => {
  const harness = createHarness({ authenticated: true, needsSetup: false });
  await startAndWaitForLoad(harness);
  harness.server.enqueue(
    (request) => request.path === "api/v1/logout" && request.method === "POST",
    () => Promise.reject(new Error("logout confirmation unavailable")),
  );
  harness.document.getElementById("auth-password").value = "must-clear";

  const logout = buttonWithText(harness.document, "Logout");
  assert.ok(logout);
  logout.click();
  await eventually(
    () => harness.hook.state.authenticationMode === "login",
    "a failed logout request must still fail closed at the authentication gate",
  );

  assert.equal(harness.hook.state.operatorAuthenticated, false);
  assert.equal(harness.document.getElementById("app").hidden, true);
  assert.equal(harness.document.getElementById("app").inert, true);
  assert.equal(harness.document.getElementById("settings-content").children.length, 0);
  assert.equal(harness.document.getElementById("auth-password").value, "");
  assert.match(
    harness.document.getElementById("auth-error").textContent,
    /could not be confirmed/i,
  );
});

test("production IIFE: first-run setup logout dynamically switches the same handler to login", async () => {
  const harness = createHarness({ authenticated: false, needsSetup: true });
  harness.hook.start();
  await eventually(
    () => harness.hook.state.authenticationMode === "setup",
    "production ensureOperatorSession should present setup mode",
  );
  const form = harness.document.getElementById("auth-form");
  assert.equal(form.listeners.get("submit").length, 1);

  harness.document.getElementById("auth-password").value = "setup-password";
  harness.document.getElementById("auth-password-confirm").value = "setup-password";
  harness.document.getElementById("auth-token").value = "owner-token";
  form.dispatch("submit");
  await eventually(
    () =>
      harness.hook.state.operatorAuthenticated &&
      harness.hook.state.bootstrap?.marker &&
      harness.hook.state.loadOperation === null,
    "production setup submission should activate and load the portal",
  );
  harness.location.hash = "#settings/operator-account";
  harness.hook.renderRoute();

  const logout = buttonWithText(harness.document, "Logout");
  assert.ok(logout, "setup-authenticated Account surface should render Logout");
  logout.click();
  await eventually(
    () => harness.hook.state.authenticationMode === "login",
    "logout after setup should transition current auth mode to login",
  );
  await submitAuthentication(harness, "login-password");

  assert.equal(harness.server.count("api/v1/setup", "POST"), 1);
  assert.equal(harness.server.count("api/v1/login", "POST"), 1);
  assert.equal(form.listeners.get("submit").length, 1);
  assert.equal(harness.hook.state.authenticationMode, "authenticated");
});

test("production IIFE: stale real loadAll cannot poison re-login and a new load", async () => {
  const harness = createHarness({ authenticated: true, needsSetup: false });
  await startAndWaitForLoad(harness);
  const currentMarker = harness.hook.state.bootstrap.marker;
  const delayedBootstrap = deferred();
  const delayedProviders = deferred();
  harness.server.enqueue(
    (request) => request.path === "api/v1/bootstrap" && request.method === "GET",
    () => delayedBootstrap.promise,
  );
  harness.server.enqueue(
    (request) =>
      request.path === "api/v1/provider-settings?refresh=true" &&
      request.method === "GET",
    () => delayedProviders.promise,
  );

  const staleLoad = harness.hook.loadAll(true);
  await eventually(
    () =>
      harness.server.count("api/v1/bootstrap", "GET") >= 2 &&
      harness.server.count("api/v1/provider-settings?refresh=true", "GET") >= 1,
    "real loadAll should reach both delayed production API requests",
  );

  const logout = buttonWithText(harness.document, "Logout");
  assert.ok(logout);
  logout.click();
  await eventually(
    () => harness.hook.state.authenticationMode === "login",
    "logout should detach the stale load owner",
  );
  assert.notEqual(harness.hook.state.loadPromise, staleLoad);

  await submitAuthentication(harness, "operator-password");
  const reloginMarker = harness.hook.state.bootstrap.marker;
  assert.notEqual(reloginMarker, currentMarker);
  assert.equal(harness.hook.state.loadOperation, null);

  delayedBootstrap.resolve(
    response({ marker: "stale-bootstrap", projects: [], sessions: [], workflows: [] }),
  );
  delayedProviders.reject(new Error("late stale provider failure"));
  await nextTurn();
  await nextTurn();

  assert.equal(harness.hook.state.operatorAuthenticated, true);
  assert.equal(harness.hook.state.bootstrap.marker, reloginMarker);
  assert.equal(harness.hook.state.loadOperation, null);
  assert.equal(harness.hook.state.loadPromise, null);
  assert.equal(harness.document.getElementById("app").hidden, false);
});

test("production IIFE: delayed provider connect and auth-flow continuations stay suppressed after logout", async () => {
  const harness = createHarness({ authenticated: true, needsSetup: false });
  await startAndWaitForLoad(harness);
  const cursorConnect = deferred();
  const openCodeConnect = deferred();
  const flowSuccess = deferred();
  const flowFailure = deferred();
  const cursorConnectPath = "api/v1/provider-settings/cursorACP/connect";
  const openCodeConnectPath = "api/v1/provider-settings/openCodeACP/connect";
  const flowPath = "api/v1/provider-settings/codex/auth-flows";
  harness.server.enqueue(
    (request) => request.path === cursorConnectPath,
    () => cursorConnect.promise,
  );
  harness.server.enqueue(
    (request) => request.path === openCodeConnectPath,
    () => openCodeConnect.promise,
  );
  harness.server.enqueue(
    (request) => request.path === flowPath,
    () => flowSuccess.promise,
  );
  harness.server.enqueue(
    (request) => request.path === flowPath,
    () => flowFailure.promise,
  );

  harness.location.hash = "#settings/cli-providers";
  harness.hook.renderRoute();
  const providerContent = harness.document.getElementById("settings-content");
  const connectControls = descendants(providerContent).filter(
    (node) => node.dataset.action === "connect-external-cli-provider",
  );
  const flowControls = descendants(providerContent).filter(
    (node) => node.dataset.action === "start-auth-flow",
  );
  assert.equal(connectControls.length, 2, "production provider cards should wire both Connect controls");
  assert.equal(flowControls.length, 2, "production Codex card should wire both auth-flow controls");
  connectControls.forEach((control) => control.click());
  flowControls.forEach((control) => control.click());
  await eventually(
    () =>
      harness.server.count(cursorConnectPath, "POST") === 1 &&
      harness.server.count(openCodeConnectPath, "POST") === 1 &&
      harness.server.count(flowPath, "POST") === 2,
    "production-rendered provider controls should reach real delayed API requests",
  );

  harness.location.hash = "#settings/operator-account";
  harness.hook.renderRoute();
  const logout = buttonWithText(harness.document, "Logout");
  assert.ok(logout);
  logout.click();
  await eventually(
    () => harness.hook.state.authenticationMode === "login",
    "logout should reset state before delayed provider responses settle",
  );

  cursorConnect.resolve(response({ displayName: "Late", providerID: "cursorACP" }));
  openCodeConnect.reject(new Error("late connect failure"));
  flowSuccess.resolve(
    response({ flowID: "late-flow", providerID: "codex", state: "pending" }),
  );
  flowFailure.reject(new Error("late flow failure"));
  await nextTurn();
  await nextTurn();

  assert.equal(harness.hook.state.operatorAuthenticated, false);
  assert.equal(harness.hook.state.providers.length, 0);
  assert.equal(harness.hook.state.activeFlow, null);
  assert.equal(harness.document.getElementById("settings-content").children.length, 0);
  assert.equal(harness.document.getElementById("app").hidden, true);
  assert.equal(harness.document.getElementById("app").inert, true);
  assert.equal(harness.document.getElementById("auth-gate").hidden, false);
});
