// Node test for Model.js. Run: node test/model-test.js
const assert = require("assert")
const model = require("../Model.js")

// The five windows from a typical session, in the order a compositor lists them.
const windows = [
  { appId: "google-chrome", title: "Hacker News - Google Chrome", workspace: "1", handle: "chrome" },
  { appId: "chrome-grok.com__-Default", title: "Grok", workspace: "2", handle: "grok" },
  { appId: "org.omarchy.agent", title: "claude - ~/omarchy", workspace: "2", handle: "claude" },
  { appId: "Code", title: "Model.js - omarchy - Visual Studio Code", workspace: "3", handle: "code" },
  { appId: "libreoffice-writer", title: "Untitled 1 - LibreOffice Writer", workspace: "3", handle: "writer" },
]

const pick = (query) => model.displayRows(windows, query, 100).map((row) => row.handle)

// Most recently used first when nothing is typed; unranked windows follow in
// compositor order.
{
  const ranked = windows.map((w) => ({ ...w }))
  ranked[3].recency = 0 // code
  ranked[1].recency = 1 // grok
  const order = model.displayRows(ranked, "", 100).map((row) => row.handle)
  assert.deepStrictEqual(order, ["code", "grok", "chrome", "claude", "writer"])

  // Recency breaks ties within a score but never outranks a better match.
  const chromes = [
    { appId: "google-chrome", appName: "Google Chrome", title: "Docs", handle: "old", recency: 5 },
    { appId: "google-chrome", appName: "Google Chrome", title: "Mail", handle: "recent", recency: 1 },
    { appId: "Code", appName: "Code", title: "chrome notes", handle: "code", recency: 0 },
  ]
  assert.deepStrictEqual(
    model.displayRows(chromes, "goo", 100).map((row) => row.handle),
    ["recent", "old"]
  )
  assert.strictEqual(model.displayRows(chromes, "chrome", 100)[0].handle, "recent")
}

// The headline case: two characters, Chrome first.
assert.strictEqual(pick("ch")[0], "chrome")

// A web app is found by its domain, not its Chromium class.
assert.strictEqual(model.appName("chrome-grok.com__-Default"), "grok")
assert.strictEqual(pick("gr")[0], "grok")

// A web app on a subdomain reads as the site, not the subdomain. Taking the
// first label made every Slack window read as "app".
assert.strictEqual(
  model.appName("chrome-app.slack.com__client_T04BK5PKL_-Default"),
  "slack"
)
assert.strictEqual(model.appName("chrome-mail.google.com__mail-Default"), "google")

// The registrable label sits before the public suffix, including the
// two-part suffixes that would otherwise yield "co".
assert.strictEqual(model.siteLabel("grok.com"), "grok")
assert.strictEqual(model.siteLabel("app.slack.com"), "slack")
assert.strictEqual(model.siteLabel("www.example.com"), "example")
assert.strictEqual(model.siteLabel("example.co.uk"), "example")
assert.strictEqual(model.siteLabel("app.example.co.uk"), "example")
assert.strictEqual(model.siteLabel("localhost"), "localhost")
assert.strictEqual(model.siteLabel(""), "")

// A desktop entry name, when the overlay finds one, outranks anything derived
// from the class -- that is what lets "sl" reach a Slack web app.
const slack = [
  { appId: "chrome-app.slack.com__client_T04BK5PKL_-Default", appName: "Slack",
    title: "John Graham (DM) - Solutions360 - Slack", workspace: "5", handle: "slack" },
  { appId: "sublime_text", title: "notes.md - Sublime Text", workspace: "1", handle: "sublime" },
]
assert.strictEqual(model.displayRows(slack, "sl", 100)[0].handle, "slack")
assert.strictEqual(model.displayRows(slack, "", 100)[0].appName, "Slack")

// Without an entry name the derived fallback still fills the row.
assert.strictEqual(
  model.displayRows([{ appId: "google-chrome", title: "News", handle: "c" }], "", 100)[0].appName,
  "google-chrome"
)

// The icon the overlay resolved rides along on the row, defaulting to "".
assert.strictEqual(model.displayRows(slack, "sl", 100)[0].iconUrl, "")
assert.strictEqual(
  model.displayRows([{ appId: "code", title: "x", iconUrl: "file:///c.svg", handle: "k" }], "", 100)[0].iconUrl,
  "file:///c.svg"
)

// Agent windows share a class, so the title has to carry the match.
assert.strictEqual(pick("claude")[0], "claude")

// A word inside the title beats a loose subsequence elsewhere.
assert.strictEqual(pick("libre")[0], "writer")
assert.strictEqual(pick("visual")[0], "code")

// Subsequence matching still finds an abbreviation.
assert.ok(pick("vsc").includes("code"))

// An empty filter keeps every window in compositor order.
assert.deepStrictEqual(pick(""), ["chrome", "grok", "claude", "code", "writer"])

// A query matching nothing yields nothing, rather than every window.
assert.deepStrictEqual(pick("zzzz"), [])

// Reverse-domain ids read as their last segment.
assert.strictEqual(model.appName("org.gnome.Nautilus"), "Nautilus")
assert.strictEqual(model.appName(""), "")

// Windows with neither title nor class are skipped, not rendered blank.
assert.deepStrictEqual(model.displayRows([{ appId: "", title: "" }], "", 100), [])

// The limit is honoured.
assert.strictEqual(model.displayRows(windows, "", 2).length, 2)

// Subtitle drops a redundant app name but keeps the workspace.
assert.strictEqual(model.subtitle({ appName: "Grok", title: "Grok", workspace: "2" }), "workspace 2")
assert.strictEqual(
  model.subtitle({ appName: "google-chrome", title: "Hacker News", workspace: "1" }),
  "google-chrome  ·  workspace 1"
)

// Rows survive a missing workspace (the Hyprland lookup is best-effort).
assert.strictEqual(model.subtitle({ appName: "Code", title: "Model.js", workspace: "" }), "Code")

// Workspaces. The fixture windows sit on workspaces 1, 2, 2, 3 and 3.
{
  const workspaces = [
    { id: 1, name: "1", handle: "ws1" },
    { id: 2, name: "2", handle: "ws2", focused: true },
    { id: 3, name: "3", handle: "ws3" },
    { id: 7, name: "comms", handle: "wsComms" },
    { id: -98, name: "special:scratch", handle: "wsScratch", special: true },
  ]
  const rows = (query) => model.displayRows(windows, query, 100, workspaces)
  const handles = (query) => rows(query).map((row) => row.handle)

  // A number heads the list with that workspace, its windows grouped beneath.
  const three = rows("3")
  assert.strictEqual(three[0].kind, "workspace")
  assert.strictEqual(three[0].title, "Workspace 3")
  assert.strictEqual(three[0].handle, "ws3")
  assert.deepStrictEqual(three.slice(1, 3).map((row) => row.handle).sort(), ["code", "writer"])
  assert.ok(three[1].inWorkspace && three[2].inWorkspace)
  assert.strictEqual(three[0].windowCount, 2)

  // The overlay's placement handle survives into rows and workspace members.
  const placed = windows.map((w) => ({ ...w, placement: "place-" + w.handle }))
  const placedRows = model.displayRows(placed, "3", 100, workspaces)
  assert.deepStrictEqual(placedRows[0].members.map((row) => row.placement).sort(), ["place-code", "place-writer"])

  // Spelled-out forms reach the same workspace.
  for (const query of ["w3", "ws3", "ws 3", "workspace 3", " 3 "]) {
    assert.strictEqual(rows(query)[0].handle, "ws3", query)
  }

  // Members come most recently used first inside the workspace row.
  const ranked = windows.map((w) => ({ ...w }))
  ranked[4].recency = 0 // writer
  const ws3 = model.displayRows(ranked, "3", 100, workspaces)
  assert.deepStrictEqual(ws3[0].members.map((row) => row.handle), ["writer", "code"])
  assert.strictEqual(ws3[1].handle, "writer")

  // A number with no workspace behind it is still somewhere to go.
  const five = rows("5")
  assert.strictEqual(five[0].kind, "workspace")
  assert.strictEqual(five[0].empty, true)
  assert.strictEqual(five[0].handle, null)
  assert.strictEqual(model.subtitle(five[0]), "Empty")
  assert.strictEqual(rows("100").filter((row) => row.kind === "workspace").length, 0)

  // Named workspaces match by prefix, below an app-name prefix.
  assert.strictEqual(rows("comms")[0].handle, "wsComms")
  assert.strictEqual(rows("co").filter((row) => row.kind === "workspace")[0].handle, "wsComms")
  assert.strictEqual(rows("ws comms")[0].handle, "wsComms")

  // Text that only looks like a prefix stays an app search.
  assert.strictEqual(rows("wezterm").filter((row) => row.kind === "workspace").length, 0)
  assert.strictEqual(rows("gr")[0].handle, "grok")

  // Special workspaces are never offered, and an empty filter lists no
  // workspaces at all.
  assert.strictEqual(rows("special:scratch").filter((row) => row.kind === "workspace").length, 0)
  assert.ok(rows("").every((row) => row.kind === "window"))

  // Subtitles: a workspace says what is on it; a grouped window drops the
  // workspace it would otherwise repeat.
  assert.strictEqual(
    model.subtitle(rows("2")[0]),
    "You are here  ·  2 windows  ·  grok, agent"
  )
  assert.strictEqual(model.subtitle(three[1]).indexOf("workspace"), -1)
}

console.log("all model tests passed")
