// Pure matching and row-building logic for HopKey.
//
// Kept free of QML types so Node can load it directly: test/model-test.js
// exercises these functions without a running shell. Overlay.qml feeds it
// plain objects built from the Wayland toplevel list.

// Second-level registry labels, so "example.co.uk" reads as "example" rather
// than "co". Deliberately not a public suffix list: this is a last-resort
// fallback for windows with no desktop entry, and the short list covers what
// actually turns up.
var REGISTRY_LABELS = { co: 1, com: 1, net: 1, org: 1, ac: 1, gov: 1, edu: 1 }

// The site's own label sits immediately before the public suffix, not at the
// front of the host: "app.slack.com" is Slack, not "app". Taking the first
// label is what made a Slack window read as "app".
function siteLabel(host) {
  var labels = String(host || "").toLowerCase().split(".")
  var parts = []
  for (var i = 0; i < labels.length; i++) {
    if (labels[i]) parts.push(labels[i])
  }
  if (parts.length === 0) return ""
  if (parts.length === 1) return parts[0]

  var drop = parts.length > 2 && REGISTRY_LABELS[parts[parts.length - 2]] ? 2 : 1
  var kept = parts.slice(0, Math.max(1, parts.length - drop))
  return kept[kept.length - 1]
}

// Fallback naming for a window whose class matched no desktop entry. Omarchy
// web apps run as Chromium instances whose class encodes the site, e.g.
// "chrome-grok.com__-Default", so surface the site rather than the Chromium
// boilerplate.
function appName(appId) {
  var id = String(appId || "")
  if (!id) return ""

  var webapp = id.match(/^chrome-([^_]+?)(?:__|_-|$)/i)
  if (webapp) {
    var label = siteLabel(webapp[1])
    if (label) return label
  }

  // "org.gnome.Nautilus" reads as "Nautilus"; "google-chrome" stays whole.
  var parts = id.split(".")
  return parts[parts.length - 1] || id
}

function normalize(value) {
  return String(value || "").toLowerCase()
}

// Every character of the query appearing in order, so "vsc" still finds
// "VS Code". Weakest match, ranked last.
function subsequenceOf(haystack, query) {
  var at = 0
  for (var i = 0; i < query.length; i++) {
    at = haystack.indexOf(query[i], at)
    if (at === -1) return false
    at++
  }
  return true
}

// 0 means no match. Higher is better: a prefix of the app name beats a
// prefix of a word inside the title, which beats a loose subsequence. This
// is what makes typing "ch" land on Chrome rather than on whichever window
// happens to mention "ch" somewhere in its title.
function score(row, query) {
  var q = normalize(query)
  if (!q) return 1

  var name = normalize(row.appName)
  var title = normalize(row.title)
  var id = normalize(row.appId)

  if (name.indexOf(q) === 0) return 100
  if (wordPrefix(name, q)) return 90
  if (name.indexOf(q) !== -1) return 80
  if (title.indexOf(q) === 0) return 70
  if (wordPrefix(title, q)) return 60
  if (title.indexOf(q) !== -1) return 50
  // The raw class ranks below both, or a web app's "chrome-grok.com__-Default"
  // would answer "ch" ahead of the actual Chrome window.
  if (id.indexOf(q) === 0) return 45
  if (id.indexOf(q) !== -1) return 40
  if (subsequenceOf(name, q)) return 30
  if (subsequenceOf(title, q)) return 20
  return 0
}

function wordPrefix(haystack, query) {
  var words = haystack.split(/[\s\-_./]+/)
  for (var i = 0; i < words.length; i++) {
    if (words[i].indexOf(query) === 0) return true
  }
  return false
}

// Workspace queries. A bare number is the obvious way to ask for a
// workspace, and "ws 3", "w3" and "workspace 3" are accepted too for anyone
// who types it out. The spelled-out prefixes only take a number, except
// "ws"/"workspace" followed by a space, which also takes a name, so "wezterm"
// is never read as a request for a workspace called "ezterm".
function workspaceQuery(query) {
  var q = normalize(query).replace(/^\s+|\s+$/g, "")
  if (!q) return null
  var numbered = q.match(/^(?:workspace|ws|w)\s*(\d+)$/)
  if (numbered) return numbered[1]
  var named = q.match(/^(?:workspace|ws)\s+(\S.*)$/)
  if (named) return named[1]
  return q
}

function isNumber(text) {
  return /^\d+$/.test(String(text))
}

// Scores sit around the window scores on purpose. An exact workspace hit
// outranks everything, and its windows follow directly beneath it, so "3"
// reads as a heading with the workspace's contents under it. A named
// workspace matched by prefix ranks just under an app-name prefix, so "co"
// still lands on Code before a workspace called "comms".
var WORKSPACE_EXACT = 120
var WORKSPACE_EXACT_MEMBER = 115
var WORKSPACE_PREFIX = 97
var WORKSPACE_PREFIX_MEMBER = 96

// Hyprland creates a numbered workspace the moment you go to it, so a number
// with no workspace behind it is still somewhere you can hop to.
var MAX_EMPTY_WORKSPACE = 99

function workspaceMatches(workspaces, filterText) {
  var target = workspaceQuery(filterText)
  if (!target) return []

  var matches = []
  var list = Array.isArray(workspaces) ? workspaces : []
  for (var i = 0; i < list.length; i++) {
    var workspace = list[i]
    if (!workspace || workspace.special) continue
    var name = normalize(workspace.name)
    if (!name) continue

    if (name === target || String(workspace.id) === target) {
      matches.push({ workspace: workspace, score: WORKSPACE_EXACT, memberScore: WORKSPACE_EXACT_MEMBER })
    } else if (!isNumber(name) && target.length >= 2 && name.indexOf(target) === 0) {
      matches.push({ workspace: workspace, score: WORKSPACE_PREFIX, memberScore: WORKSPACE_PREFIX_MEMBER })
    }
  }

  if (matches.length === 0 && isNumber(target)) {
    var number = parseInt(target, 10)
    if (number >= 1 && number <= MAX_EMPTY_WORKSPACE) {
      matches.push({
        workspace: { id: number, name: String(number), handle: null, empty: true },
        score: WORKSPACE_EXACT,
        memberScore: WORKSPACE_EXACT_MEMBER
      })
    }
  }
  return matches
}

// Build the display rows from raw window descriptors. `windows` entries carry
// appId, title, workspace, an opaque `handle` the overlay activates, and an
// optional `recency` rank (0 = most recently used). Ordering is by score, then
// by recency, then by the caller's original order: an empty filter lists
// windows most recently used first, and a query breaks ties the same way, so
// "ch" with two Chrome windows lands on the one you were just in.
//
// `workspaces` is optional: { id, name, handle, focused, special }. When the
// query names one, a workspace row leads the list and that workspace's
// windows follow it, marked `inWorkspace` so the overlay can group them.
// Every row carries `kind`: "window" or "workspace".
function displayRows(windows, filterText, limit, workspaces) {
  var list = Array.isArray(windows) ? windows : []
  var max = typeof limit === "number" && limit > 0 ? limit : 100
  var scored = []

  var matchedWorkspaces = workspaceMatches(workspaces, filterText)
  var memberScores = {}
  for (var m = 0; m < matchedWorkspaces.length; m++) {
    var key = normalize(matchedWorkspaces[m].workspace.name)
    memberScores[key] = Math.max(memberScores[key] || 0, matchedWorkspaces[m].memberScore)
  }

  for (var i = 0; i < list.length; i++) {
    var window = list[i]
    if (!window) continue

    var title = String(window.title || "")
    var appId = String(window.appId || "")
    if (!title && !appId) continue

    // The overlay resolves a desktop entry per class and passes its name in;
    // deriving one from the class is only a fallback. Ranking reads appName,
    // so an entry name is what makes "sl" reach Slack.
    var name = String(window.appName || "") || appName(appId)

    var row = {
      kind: "window",
      appId: appId,
      appName: name,
      title: title || name,
      workspace: String(window.workspace || ""),
      iconUrl: String(window.iconUrl || ""),
      handle: window.handle,
      // Opaque to this file: the overlay's hook for placing the window in a
      // workspace miniature.
      placement: window.placement || null,
      recency: typeof window.recency === "number" ? window.recency : Infinity,
      order: i,
      inWorkspace: false
    }

    var matched = score(row, filterText)
    var memberScore = memberScores[normalize(row.workspace)] || 0
    if (memberScore > matched) {
      matched = memberScore
      row.inWorkspace = true
    }
    if (matched === 0) continue

    row.score = matched
    scored.push(row)
  }

  for (var w = 0; w < matchedWorkspaces.length; w++) {
    scored.push(workspaceRow(matchedWorkspaces[w], scored))
  }

  scored.sort(function(left, right) {
    if (left.score !== right.score) return right.score - left.score
    // A workspace heads its own windows when their scores could tie.
    if (left.kind !== right.kind) return left.kind === "workspace" ? -1 : 1
    // Compared, not subtracted: two unranked windows are Infinity - Infinity.
    if (left.recency !== right.recency) return left.recency < right.recency ? -1 : 1
    return left.order - right.order
  })

  return scored.slice(0, max)
}

// The workspace row summarises what is on it: its windows most recently used
// first (for the overlay's miniature), and the distinct apps in that order
// (for the subtitle).
function workspaceRow(match, windowRows) {
  var workspace = match.workspace
  var name = String(workspace.name || workspace.id || "")
  var members = []
  for (var i = 0; i < windowRows.length; i++) {
    if (windowRows[i].kind === "window" && normalize(windowRows[i].workspace) === normalize(name))
      members.push(windowRows[i])
  }
  members.sort(function(left, right) {
    if (left.recency !== right.recency) return left.recency < right.recency ? -1 : 1
    return left.order - right.order
  })

  var apps = []
  for (var j = 0; j < members.length; j++) {
    var app = members[j].appName || members[j].title
    if (app && apps.indexOf(app) === -1) apps.push(app)
  }

  return {
    kind: "workspace",
    appId: "",
    appName: "",
    title: "Workspace " + name,
    workspace: name,
    workspaceId: workspace.id,
    iconUrl: "",
    handle: workspace.handle || null,
    members: members,
    apps: apps,
    windowCount: members.length,
    empty: members.length === 0,
    focused: !!workspace.focused,
    recency: -1,
    order: -1,
    inWorkspace: false,
    score: match.score
  }
}

// Subtext under each row. A window gets the app it belongs to and where it
// lives, dropping the app name when it would only repeat the title. A
// workspace gets what is on it.
function subtitle(row) {
  if (!row) return ""

  if (row.kind === "workspace") {
    var summary = []
    if (row.focused) summary.push("You are here")
    if (row.empty) {
      summary.push("Empty")
    } else {
      summary.push(row.windowCount === 1 ? "1 window" : row.windowCount + " windows")
      summary.push(row.apps.slice(0, 4).join(", ") + (row.apps.length > 4 ? ", …" : ""))
    }
    return summary.join("  ·  ")
  }

  var parts = []
  if (row.appName && normalize(row.appName) !== normalize(row.title)) parts.push(row.appName)
  // A window grouped under its workspace row already says where it lives.
  if (row.workspace && !row.inWorkspace) parts.push("workspace " + row.workspace)
  return parts.join("  ·  ")
}

// Mirrors shell/plugins/menu/MenuModel.js: the same file loads as a QML
// script import and as a Node module, so the logic above can be tested
// without a running shell.
if (typeof module !== "undefined") {
  module.exports = {
    appName: appName,
    siteLabel: siteLabel,
    subsequenceOf: subsequenceOf,
    wordPrefix: wordPrefix,
    score: score,
    displayRows: displayRows,
    workspaceQuery: workspaceQuery,
    workspaceMatches: workspaceMatches,
    subtitle: subtitle
  }
}
