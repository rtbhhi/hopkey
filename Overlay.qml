import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Fullscreen window switcher. Summoned by the shell with
//   omarchy-shell shell toggle io.github.rtbhhi.hopkey
// then filtered by typing and dismissed by picking a window or pressing
// Escape. The list comes from the Wayland toplevel manager, so it tracks
// windows live rather than sampling `hyprctl clients` at open time.
Item {
  id: root

  // The shell reads `opened` to keep its own toggle state in sync, and calls
  // open()/close() over IPC. Both halves of that contract are required.
  property bool opened: false
  property string filterText: ""
  property int selectedIndex: 0
  property bool cursorActive: false
  property var rows: []

  // Injected by omarchy-shell when this plugin is loaded. Only used for icon
  // lookup, so every path below degrades to a text-only list without it.
  property var shell: null
  readonly property var appLibrary: root.shell ? root.shell.appLibrary : null

  // Shares the [menu] surface tokens, so a theme that styles the Omarchy
  // menu styles this switcher too, with no per-plugin color config.
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int headerHeight: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)
  property int contentSpacing: Style.spacing.md
  property int cardWidth: Math.min(Style.space(760), panel.width - Style.gapsOut * 2)
  property int cardHeight: Math.min(Style.space(760), panel.height - Style.gapsOut * 2)
  property int rowHeight: Math.max(Style.space(52), Style.font.title + Style.font.caption + Style.spacing.rowPaddingX * 2)
  property int iconSize: Style.font.iconLarge

  // The best few matches get a snapshot of the window, since those are the
  // ones Enter is about to land on; the long tail stays text so the list
  // still scans quickly and does not capture every open window per keystroke.
  property int previewCount: 3
  property int previewHeight: Style.space(128)
  property int previewWidth: Math.round(root.previewHeight * 16 / 10)
  property int previewRowHeight: root.previewHeight + Style.space(16)
  // How far the snapshot zooms into the window's upper-left corner: the box
  // shows 1/previewZoom of the window's width and of its height.
  property real previewZoom: 2
  property int dividerHeight: Math.max(Style.space(28), Style.font.caption + Style.space(14))
  // How far a workspace's windows sit in from its row.
  property int groupIndent: Style.space(20)

  function open(payloadJson) {
    root.filterText = ""
    root.selectedIndex = 0
    root.cursorActive = true
    root.disarmPointer()
    root.rebuildDisplay()
    // Keeps Hyprland's focus history fresh for windows this plugin has not
    // seen focused yet; it lands asynchronously and serves the next opening.
    try { Hyprland.refreshToplevels() } catch (error) {}
    // The shell may start before a newly installed app has placed its icon,
    // and the Qt icon cache never re-scans. Refresh so icons appear live.
    root.entryCache = ({})
    if (root.appLibrary) root.appLibrary.refreshIcons()
    root.opened = true
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open("{}")
  }

  // Hyprland knows things about a window the Wayland protocol does not: its
  // workspace and its place in the focus history. Find its entry when the
  // mapping is available, and let every caller degrade when it is not.
  function hyprToplevelFor(toplevel) {
    try {
      var hyprToplevels = Hyprland.toplevels.values
      for (var i = 0; i < hyprToplevels.length; i++) {
        var entry = hyprToplevels[i]
        if (entry && entry.wayland === toplevel) return entry
      }
    } catch (error) {
      // Older or newer Hyprland bindings: the switcher still works without it.
    }
    return null
  }

  function workspaceFor(hyprEntry) {
    if (!hyprEntry || !hyprEntry.workspace) return ""
    return String(hyprEntry.workspace.name || hyprEntry.workspace.id || "")
  }

  // Windows in the order they were last focused, most recent first. The
  // plugin stays loaded (keepLoaded), so this follows focus the whole time the
  // shell runs, not just while the overlay is open. Destroyed windows read
  // back as null and are dropped on the next change.
  property var focusHistory: []

  function noteFocus(toplevel) {
    if (!toplevel) return
    var next = [toplevel]
    for (var i = 0; i < root.focusHistory.length && next.length < 64; i++) {
      var seen = root.focusHistory[i]
      if (seen && seen !== toplevel) next.push(seen)
    }
    root.focusHistory = next
  }

  Connections {
    target: ToplevelManager
    function onActiveToplevelChanged() { root.noteFocus(ToplevelManager.activeToplevel) }
  }

  Component.onCompleted: root.noteFocus(ToplevelManager.activeToplevel)

  // Windows focused since the shell started rank by this plugin's own
  // history. Anything older falls back to Hyprland's focus history as of its
  // last client refresh, then to no rank at all (compositor order).
  function rawRecency(toplevel, hyprEntry) {
    var tracked = root.focusHistory.indexOf(toplevel)
    if (tracked !== -1) return tracked
    var ipc = hyprEntry ? hyprEntry.lastIpcObject : null
    if (ipc && typeof ipc.focusHistoryID === "number" && ipc.focusHistoryID >= 0)
      return 1000 + ipc.focusHistoryID
    return 1000000
  }

  // A Wayland class is not a desktop-entry id, so the match takes three tries:
  // Quickshell's heuristic lookup, an exact id, and finally the web-app
  // fallback below. Returns null when the window has no entry at all.
  function desktopEntryFor(appId) {
    var id = String(appId || "")
    if (!id) return null

    var entry = null
    try { entry = DesktopEntries.heuristicLookup(id) } catch (error) { entry = null }
    if (!entry) {
      try { entry = DesktopEntries.byId(id) } catch (error) { entry = null }
    }
    if (!entry) entry = root.webappEntry(id)
    return entry
  }

  // The entry supplies both halves of a row's identity: the name the user
  // actually calls the app, and its icon. Deriving a name from the class is
  // guesswork -- "chrome-app.slack.com__client_..." is Slack, which no amount
  // of string surgery reliably says -- so prefer the entry and let Model.js
  // fall back only when there is none.
  //
  // Cached per class because collectWindows() runs on every keystroke and the
  // web-app fallback walks the whole entry list. open() clears it, so a newly
  // installed app is picked up the next time the overlay is summoned.
  property var entryCache: ({})

  function entryInfoFor(appId) {
    var id = String(appId || "")
    if (!id) return { name: "", iconUrl: "" }

    var cached = root.entryCache[id]
    if (cached) return cached

    var entry = root.desktopEntryFor(id)
    var icon = entry ? String(entry.icon || "") : ""
    var info = {
      name: entry ? String(entry.name || "") : "",
      iconUrl: (icon && root.appLibrary) ? root.appLibrary.iconSource(icon) : ""
    }
    root.entryCache[id] = info
    return info
  }

  // Omarchy web apps are Chromium instances classed "chrome-<host>__<path>",
  // and omarchy-launch-webapp writes their .desktop files without a
  // StartupWMClass, so neither lookup above can reach them. The host is the one
  // thing the class and the Exec line share, so match on that.
  function webappEntry(appId) {
    var webapp = String(appId).match(/^chrome-([^_]+?)(?:__|_-|$)/i)
    if (!webapp) return null

    var host = webapp[1].toLowerCase()
    if (!host) return null

    var entries = []
    try { entries = DesktopEntries.applications.values || [] } catch (error) { return null }

    for (var i = 0; i < entries.length; i++) {
      var entry = entries[i]
      if (!entry) continue
      var command = String(entry.execString || "").toLowerCase()
      if (command.indexOf("//" + host) !== -1 || command.indexOf("//www." + host) !== -1) return entry
    }
    return null
  }

  function collectWindows() {
    var out = []
    var toplevels = []
    try { toplevels = ToplevelManager.toplevels.values } catch (error) { return out }

    var current = null
    var currentRank = 1000000
    for (var i = 0; i < toplevels.length; i++) {
      var toplevel = toplevels[i]
      if (!toplevel) continue
      var info = root.entryInfoFor(toplevel.appId || "")
      var hyprEntry = root.hyprToplevelFor(toplevel)
      var window = {
        appId: toplevel.appId || "",
        appName: info.name,
        iconUrl: info.iconUrl,
        title: toplevel.title || "",
        workspace: root.workspaceFor(hyprEntry),
        recency: root.rawRecency(toplevel, hyprEntry),
        // Where Hyprland has the window, for a workspace row's miniature.
        placement: hyprEntry,
        handle: toplevel
      }
      if (window.recency < currentRank) {
        current = window
        currentRank = window.recency
      }
      out.push(window)
    }

    // The most recent window is the one you summoned HopKey from, and the
    // one place you never need to switch to. Send it to the back so the top
    // row, and Enter, is the window you were in before it.
    if (current && out.length > 1) current.recency = Infinity
    return out
  }

  // Special workspaces (scratchpads) are left out by Model.js: hopping "to" one
  // toggles it over the current workspace, which is not what picking a
  // workspace from a list means.
  function collectWorkspaces() {
    var out = []
    var workspaces = []
    try { workspaces = Hyprland.workspaces.values } catch (error) { return out }

    for (var i = 0; i < workspaces.length; i++) {
      var workspace = workspaces[i]
      if (!workspace) continue
      var name = String(workspace.name || workspace.id || "")
      out.push({
        id: workspace.id,
        name: name,
        focused: !!workspace.focused,
        special: workspace.id < 0 || name.indexOf("special:") === 0,
        handle: workspace
      })
    }
    return out
  }

  function rebuildDisplay() {
    root.rows = Model.displayRows(root.collectWindows(), root.filterText, 100, root.collectWorkspaces())

    if (root.rows.length === 0) root.selectedIndex = 0
    else if (root.selectedIndex >= root.rows.length) root.selectedIndex = root.rows.length - 1
    else if (root.selectedIndex < 0) root.selectedIndex = 0

    Qt.callLater(function() {
      if (root.rows.length > 0) resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
    })
  }

  function select(delta) {
    if (root.rows.length === 0) return
    root.disarmPointer()
    if (!root.cursorActive) {
      root.cursorActive = true
      root.selectedIndex = delta < 0 ? root.rows.length - 1 : 0
    } else {
      root.selectedIndex = (root.selectedIndex + delta + root.rows.length) % root.rows.length
    }
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function selectAbsolute(index) {
    if (root.rows.length === 0) return
    root.disarmPointer()
    root.cursorActive = true
    root.selectedIndex = Math.max(0, Math.min(index, root.rows.length - 1))
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function setFilter(nextFilter) {
    root.filterText = nextFilter
    root.selectedIndex = 0
    root.cursorActive = true
    root.disarmPointer()
    root.rebuildDisplay()
  }

  function disarmPointer() {
    pointerGate.reset()
  }

  function selectFromPointer(index, item, mouse) {
    if (!pointerGate.moved(item, mouse)) return
    root.cursorActive = true
    root.selectedIndex = index
  }

  // Drop the layer surface before focusing, so the compositor is not asked to
  // activate a window while this overlay still holds exclusive keyboard focus.
  function activateIndex(index) {
    if (index < 0 || index >= root.rows.length) return
    var row = root.rows[index]
    root.opened = false
    if (row.kind === "workspace") {
      var workspace = row.workspace
      Qt.callLater(function() { root.focusWorkspace(workspace) })
      return
    }
    var handle = row.handle
    if (!handle) return
    Qt.callLater(function() {
      try { handle.activate() } catch (error) {
        console.warn("hopkey: could not activate window:", error)
      }
    })
  }

  // Goes by name, which also reaches a numbered workspace that does not exist
  // yet: Hyprland creates it on arrival. Dispatched through hyprctl the way
  // the Omarchy bar does it, in whichever syntax the running config speaks.
  function focusWorkspace(name) {
    var target = String(name || "")
    if (!target) return
    var command = Hyprland.usingLua
      ? "hl.dsp.focus({ workspace = \"" + target.replace(/\\/g, "\\\\").replace(/"/g, "\\\"") + "\" })"
      : "workspace " + (/^\d+$/.test(target) ? target : "name:" + target)
    // execArgv, not a shell string: a workspace name is Hyprland's data, and
    // it should reach hyprctl as one argument whatever it contains.
    Util.execArgv(["hyprctl", "dispatch", command])
  }

  // Keep the list honest while it is on screen: a window that closes or
  // retitles behind the overlay should not stay pickable, and a workspace
  // that empties out should stop claiming its windows.
  Connections {
    target: ToplevelManager.toplevels
    enabled: root.opened
    function onValuesChanged() { root.rebuildDisplay() }
  }

  Connections {
    target: Hyprland.workspaces
    enabled: root.opened
    function onValuesChanged() { root.rebuildDisplay() }
  }

  PointerMoveGate {
    id: pointerGate
    referenceItem: card
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-hopkey"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            if (root.filterText) root.setFilter("")
            else root.close()
            event.accepted = true
          } else if (Util.editsFilter(event, root.filterText)) {
            root.setFilter(Util.editedFilter(event, root.filterText))
            event.accepted = true
          } else if (event.key === Qt.Key_Up || (event.key === Qt.Key_Tab && (event.modifiers & Qt.ShiftModifier))) {
            root.select(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Down || event.key === Qt.Key_Tab) {
            root.select(1)
            event.accepted = true
          } else if (event.key === Qt.Key_PageUp) {
            root.select(-6)
            event.accepted = true
          } else if (event.key === Qt.Key_PageDown) {
            root.select(6)
            event.accepted = true
          } else if (event.key === Qt.Key_Home) {
            root.selectAbsolute(0)
            event.accepted = true
          } else if (event.key === Qt.Key_End) {
            root.selectAbsolute(root.rows.length - 1)
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.activateIndex(root.selectedIndex)
            event.accepted = true
          } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
            root.setFilter(root.filterText + event.text)
            event.accepted = true
          }
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.contentSpacing

        Rectangle {
          width: parent.width
          height: root.headerHeight
          radius: root.cornerRadius
          color: "transparent"

          Text {
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.filterText || "Search or click an app to hop to…"
            color: root.foreground
            opacity: root.filterText ? 1 : 0.58
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideRight
          }
        }

        Item {
          width: parent.width
          height: parent.height - root.headerHeight - root.contentSpacing
          clip: true

          ListView {
            id: resultList
            anchors.fill: parent
            model: root.rows
            clip: true
            spacing: Style.space(4)
            boundsBehavior: Flickable.StopAtBounds

            delegate: Item {
              id: row
              required property int index
              required property var modelData

              readonly property bool hasCursor: root.cursorActive && index === root.selectedIndex

              readonly property string iconUrl: String(modelData.iconUrl || "")
              readonly property bool hasIcon: iconUrl.length > 0
              readonly property bool isWorkspace: modelData.kind === "workspace"
              readonly property bool inWorkspace: !!modelData.inWorkspace
              // A workspace row's preview is a miniature of the workspace, drawn
              // even when it is empty, so it needs no window handle.
              readonly property bool hasPreview: index < root.previewCount && (isWorkspace || !!modelData.handle)
              // The first text-only row carries the divider above it, so the
              // divider moves with the list and needs no model entry of its own.
              readonly property bool startsMore: index === root.previewCount
              readonly property int dividerSpace: startsMore ? root.dividerHeight : 0

              width: ListView.view.width
              height: dividerSpace + rowBody.height

              // Snapshots above, plain rows below: say how many plain rows
              // follow, so a long tail reads as "keep scrolling" and not as
              // the end of the list.
              Item {
                visible: row.startsMore
                width: parent.width
                height: row.dividerSpace

                Rectangle {
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(12)
                  anchors.right: moreLabel.left
                  anchors.rightMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  height: 1
                  color: root.foreground
                  opacity: 0.18
                }

                Text {
                  id: moreLabel
                  anchors.centerIn: parent
                  textFormat: Text.PlainText
                  text: (root.rows.length - root.previewCount) + " more"
                  color: root.foreground
                  opacity: 0.5
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Rectangle {
                  anchors.left: moreLabel.right
                  anchors.leftMargin: Style.space(10)
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(12)
                  anchors.verticalCenter: parent.verticalCenter
                  height: 1
                  color: root.foreground
                  opacity: 0.18
                }
              }

              // Windows listed under a workspace row hang off a guide line, so
              // "3" reads as a heading with that workspace's contents beneath.
              Rectangle {
                visible: row.inWorkspace
                x: Math.round(root.groupIndent / 2)
                y: row.dividerSpace
                width: Math.max(1, Style.space(2))
                height: rowBody.height + Style.space(4)
                radius: width / 2
                color: root.foreground
                opacity: 0.18
              }

              Rectangle {
                id: rowBody
                x: row.inWorkspace ? root.groupIndent : 0
                y: row.dividerSpace
                width: parent.width - x
                height: row.hasPreview ? root.previewRowHeight : root.rowHeight
                radius: root.cornerRadius
                color: row.hasCursor ? root.selectedBackground : "transparent"

                // A workspace row past the thumbnails wears its name where a
                // window row wears its app icon.
                Rectangle {
                  id: workspaceBadge
                  visible: row.isWorkspace && !row.hasPreview
                  width: root.iconSize
                  height: root.iconSize
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(12)
                  anchors.verticalCenter: parent.verticalCenter
                  radius: root.cornerRadius
                  color: "transparent"
                  border.width: Math.max(1, Style.space(2))
                  border.color: row.hasCursor ? root.selectedText : root.foreground
                  opacity: 0.8

                  Text {
                    anchors.fill: parent
                    anchors.margins: Style.space(2)
                    textFormat: Text.PlainText
                    text: row.modelData.workspace
                    color: row.hasCursor ? root.selectedText : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.title
                    font.bold: true
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    fontSizeMode: Text.Fit
                    minimumPixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }

                Image {
                  id: rowIcon
                  visible: row.hasIcon && !row.hasPreview
                  width: root.iconSize
                  height: root.iconSize
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(12)
                  anchors.verticalCenter: parent.verticalCenter
                  fillMode: Image.PreserveAspectFit
                  // Decode at physical pixels: a logical-size decode leaves PNG
                  // icons upscaled and blurry on HiDPI displays.
                  sourceSize.width: width * Screen.devicePixelRatio
                  sourceSize.height: height * Screen.devicePixelRatio
                  source: rowIcon.visible ? row.iconUrl : ""
                  asynchronous: true
                }

                Rectangle {
                  id: preview
                  visible: row.hasPreview
                  width: root.previewWidth
                  height: root.previewHeight
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  radius: root.cornerRadius
                  color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
                  clip: true

                  // Only the window's upper-left corner is shown. A whole
                  // window shrunk to thumbnail size is unreadable, while its
                  // corner (tab strip, file name, first lines of content) is
                  // what tells two windows of the same app apart.
                  //
                  // The corner is laid out at the capture's own resolution and
                  // rendered into a mipmapped layer, which the `scale` below
                  // then shrinks into the box. Scaling the capture directly
                  // samples only a few of the several source pixels behind each
                  // thumbnail pixel, which turns text into jagged noise; the
                  // mipmap averages all of them. Layering just the corner, not
                  // the whole window, keeps each texture to the pixels shown.
                  Item {
                    id: crop
                    readonly property real dpr: Screen.devicePixelRatio
                    // The capture's size in this item's logical units, so that
                    // one layer texel lands on one captured pixel.
                    readonly property real nativeWidth: snapshot.sourceSize.width / dpr
                    readonly property real nativeHeight: snapshot.sourceSize.height / dpr
                    readonly property real fit: (nativeWidth > 0 && nativeHeight > 0)
                      ? Math.max(preview.width * root.previewZoom / nativeWidth, preview.height * root.previewZoom / nativeHeight)
                      : 1

                    width: preview.width / fit
                    height: preview.height / fit
                    transformOrigin: Item.TopLeft
                    scale: fit
                    clip: true

                    layer.enabled: row.hasPreview && !row.isWorkspace
                    layer.mipmap: true
                    layer.smooth: true
                    layer.textureSize: Qt.size(Math.ceil(width * dpr), Math.ceil(height * dpr))

                    // One still frame, not a live feed: the overlay is open for
                    // a second or two, and a live capture of three windows would
                    // keep them all rendering for nothing. The delegate is
                    // rebuilt on every keystroke, so a snapshot is never more
                    // stale than the last thing typed.
                    ScreencopyView {
                      id: snapshot
                      width: crop.nativeWidth
                      height: crop.nativeHeight
                      captureSource: row.hasPreview && !row.isWorkspace ? row.modelData.handle : null
                      live: false
                      paintCursor: false
                    }
                  }

                  // A workspace row previews the whole workspace: its monitor,
                  // scaled into the box, with each window snapshotted where it
                  // actually sits. Positions come from Hyprland's client list,
                  // which open() refreshes, and are bound live so the miniature
                  // settles as that refresh lands.
                  Item {
                    id: miniature
                    visible: row.isWorkspace && row.hasPreview
                    anchors.fill: parent
                    anchors.margins: Style.space(6)

                    readonly property var workspaceHandle: row.isWorkspace ? row.modelData.handle : null
                    readonly property var monitor: workspaceHandle ? workspaceHandle.monitor : null
                    readonly property var monitorIpc: monitor ? monitor.lastIpcObject : null
                    // Hyprland reports monitor size in physical pixels and window
                    // geometry in layout (logical) pixels; a 90 or 270 degree
                    // transform swaps the monitor's sides.
                    readonly property bool rotated: !!monitorIpc && (monitorIpc.transform % 2) === 1
                    readonly property real monitorScale: monitor && monitor.scale > 0 ? monitor.scale : 1
                    readonly property real areaX: monitor ? monitor.x : 0
                    readonly property real areaY: monitor ? monitor.y : 0
                    readonly property real areaWidth: monitor ? (rotated ? monitor.height : monitor.width) / monitorScale : 0
                    readonly property real areaHeight: monitor ? (rotated ? monitor.width : monitor.height) / monitorScale : 0
                    readonly property real fit: (areaWidth > 0 && areaHeight > 0)
                      ? Math.min(width / areaWidth, height / areaHeight)
                      : 0

                    Rectangle {
                      anchors.centerIn: parent
                      width: miniature.fit > 0 ? miniature.areaWidth * miniature.fit : parent.width
                      height: miniature.fit > 0 ? miniature.areaHeight * miniature.fit : parent.height
                      radius: Math.max(2, root.cornerRadius / 2)
                      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)
                      border.width: 1
                      border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.16)
                      clip: true

                      // Most recent window drawn last, so it lands on top where
                      // floating windows overlap.
                      Repeater {
                        model: miniature.fit > 0 ? row.modelData.members.slice().reverse() : []

                        delegate: Rectangle {
                          id: tile
                          required property var modelData

                          readonly property var ipc: modelData.placement ? modelData.placement.lastIpcObject : null
                          readonly property bool placed: !!ipc && !!ipc.at && !!ipc.size
                          readonly property string tileIcon: String(modelData.iconUrl || "")

                          visible: placed
                          x: placed ? (ipc.at[0] - miniature.areaX) * miniature.fit : 0
                          y: placed ? (ipc.at[1] - miniature.areaY) * miniature.fit : 0
                          width: placed ? Math.max(4, ipc.size[0] * miniature.fit) : 0
                          height: placed ? Math.max(4, ipc.size[1] * miniature.fit) : 0
                          z: placed && ipc.floating ? 1 : 0
                          radius: 2
                          color: root.background
                          border.width: 1
                          border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.35)
                          clip: true

                          ScreencopyView {
                            anchors.fill: parent
                            anchors.margins: 1
                            captureSource: tile.placed ? tile.modelData.handle : null
                            live: false
                            paintCursor: false
                          }

                          Image {
                            visible: tile.tileIcon.length > 0
                            anchors.centerIn: parent
                            width: Math.min(root.iconSize, Math.min(tile.width, tile.height) * 0.5)
                            height: width
                            fillMode: Image.PreserveAspectFit
                            sourceSize.width: root.iconSize * Screen.devicePixelRatio
                            sourceSize.height: root.iconSize * Screen.devicePixelRatio
                            source: visible ? tile.tileIcon : ""
                            asynchronous: true
                          }
                        }
                      }
                    }

                    // An empty workspace (or one Hyprland has not placed yet)
                    // shows its name, so the box never reads as a failed capture.
                    Text {
                      visible: row.modelData.empty === true || miniature.fit === 0
                      anchors.centerIn: parent
                      textFormat: Text.PlainText
                      text: row.modelData.workspace
                      color: root.foreground
                      opacity: 0.55
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.displayLarge
                      font.bold: true
                    }
                  }

                  // Until the first frame lands, or when the compositor will not
                  // export this window, show the app icon in its place.
                  Image {
                    readonly property bool badge: snapshot.hasContent
                    visible: row.hasIcon && row.hasPreview
                    width: badge ? Style.font.title : root.iconSize
                    height: width
                    anchors.centerIn: badge ? undefined : parent
                    anchors.right: badge ? parent.right : undefined
                    anchors.bottom: badge ? parent.bottom : undefined
                    anchors.margins: Style.space(6)
                    fillMode: Image.PreserveAspectFit
                    sourceSize.width: root.iconSize * Screen.devicePixelRatio
                    sourceSize.height: root.iconSize * Screen.devicePixelRatio
                    source: visible ? row.iconUrl : ""
                    asynchronous: true
                  }
                }

                Column {
                  anchors.left: row.hasPreview ? preview.right : (row.isWorkspace ? workspaceBadge.right : (row.hasIcon ? rowIcon.right : parent.left))
                  anchors.leftMargin: Style.space(12)
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(12)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(2)

                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    text: row.modelData.title
                    color: row.hasCursor ? root.selectedText : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.title
                    elide: Text.ElideRight
                    wrapMode: Text.NoWrap
                  }

                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    text: Model.subtitle(row.modelData)
                    visible: text.length > 0
                    color: row.hasCursor ? root.selectedText : root.foreground
                    opacity: 0.62
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                    wrapMode: Text.NoWrap
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onPositionChanged: function(mouse) {
                    root.selectFromPointer(row.index, rowBody, mouse)
                  }
                  onClicked: {
                    root.cursorActive = true
                    root.selectedIndex = row.index
                    root.activateIndex(row.index)
                  }
                }
              }
            }
          }

          Column {
            anchors.centerIn: parent
            spacing: Style.space(8)
            visible: root.rows.length === 0

            Text {
              text: "󰖯"
              color: root.selectedText
              opacity: 0.8
              font.family: root.fontFamily
              font.pixelSize: Style.font.displayLarge
              horizontalAlignment: Text.AlignHCenter
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              text: root.filterText ? "No windows match “" + root.filterText + "”" : "No open windows"
              color: root.foreground
              opacity: 0.7
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              horizontalAlignment: Text.AlignHCenter
              width: parent.width
            }
          }
        }
      }
    }
  }
}
