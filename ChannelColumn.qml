import QtQuick
import Quickshell.Services.Pipewire
import qs.Ui
import qs.Commons
import "EqPresets.js" as EqPresets

// One channel column (image #3, item 3-5). `node` is null until the
// channel's sink/source comes up — every binding below already tolerates
// that.
Item {
  id: root

  // Raised while this channel's device dropdown is open, so its expanded
  // list can paint over a neighboring ChannelColumn if it's wide enough to
  // spill past this column's own width — same reasoning as
  // DeviceDropdown.qml's own `z` boost one level down (needed at every
  // level between the list and whatever it must paint over, not just on
  // the list itself).
  z: root.dropdownOpen ? 1000 : 0

  property QtObject bar: null
  property string channelId: ""
  property string channelName: ""
  property string channelType: "output" // "output" | "input"
  property string device: ""
  property var node: null
  property var outputNode: null
  property bool panelOpen: false
  property var apps: []
  property var eq: null
  property var presets: []
  property var availableDevices: []
  property var dragGhostRef: null

  signal headerClicked()
  signal deleteRequested()
  signal renameRequested(string newName)
  signal appDropped(var streamNode, string zoneId)
  signal deviceRequested(string deviceName)
  signal dropdownToggleRequested()
  signal dropdownCloseRequested()
  // Fired when another channel's header is dropped onto THIS channel's
  // header — draggedChannelId is the channel that was dragged; this
  // channel (root.channelId) is where it should end up. See
  // BarWidget.qml's onChannelReorderRequested / ChannelManager.reorderChannel.
  signal reorderRequested(string draggedChannelId)

  // Whether THIS channel's device dropdown is the one currently open —
  // bound from outside (BarWidget owns which single channel's dropdown, if
  // any, is open) so opening one always closes any other.
  property bool dropdownOpen: false

  property bool editingName: false

  function _commitRename() {
    var trimmed = String(nameEdit.text || "").trim()
    if (trimmed && trimmed !== root.channelName) root.renameRequested(trimmed)
    root.editingName = false
  }

  readonly property real volume: node && node.audio ? node.audio.volume : 0
  readonly property bool muted: node && node.audio ? node.audio.muted : false
  readonly property color fg: bar ? bar.foreground : Color.foreground
  // Hashed off this channel's id into the active theme's palette — see
  // BarWidget.channelColorFor. Falls back to the shared accent if the
  // caller doesn't set it (e.g. an unstyled test instantiation).
  property color channelColor: Color.accent

  function toggleMute() {
    if (node && node.audio) node.audio.muted = !node.audio.muted
  }

  implicitWidth: column.implicitWidth
  implicitHeight: column.implicitHeight

  // Watches the "_output" node (right before this channel's audio reaches
  // the physical device), NOT `node` (the capture-side sink whose
  // .audio.volume the fader controls below) — see BarWidget.qml's
  // baseChannels comment for why: the capture side reports the incoming
  // app audio level uncapped by this channel's own volume.
  PwNodePeakMonitor {
    id: peakMonitor
    node: root.outputNode
    enabled: root.panelOpen && !!root.outputNode
  }

  Column {
    id: column
    // Widened from 96 — narrower device-dropdown/app-pill labels were
    // truncating hard, and two adjacent columns' expanded device dropdowns
    // could overlap each other (now also fixed independently by only ever
    // letting one dropdown be open at a time — see BarWidget's
    // openDeviceDropdownChannelId — but the extra width still helps
    // legibility on its own).
    width: Style.space(116)
    spacing: Style.space(6)

    // Wraps the header Row so a reorder DropArea can overlay it below:
    // a DropArea can't safely live directly inside `column` (a Column
    // would lay it out as an extra stacked row, adding unwanted vertical
    // space) or directly inside the Row itself (Row would try to give it
    // layout width like any other child, breaking the row) — same
    // "wrap a fixed-size outer Item" shape the drag *source* side already
    // uses one level down (headerDragWrap/headerLabel).
    Item {
      id: headerRowContainer
      anchors.horizontalCenter: parent.horizontalCenter
      width: headerRow.implicitWidth
      // headerRow.height (NOT .implicitHeight): headerRow pins its own
      // actual `height` to headerLabel.implicitHeight specifically to
      // avoid TextInput's taller natural sizing inflating this row (see
      // the comment on that binding below) — but a Row's `implicitHeight`
      // is computed from content and is NOT affected by that explicit
      // height override, so it stayed at the taller, un-pinned value. This
      // container was reading that wrong (taller) measurement, making
      // ChannelColumn's whole header a few px taller than MasterColumn's
      // plain-Text header and pushing everything below it (device
      // dropdown, fader, %, mute icon, Apps zone) down relative to MASTER.
      height: headerRow.height

      // Hover feedback while another channel's header is being dragged
      // over this one — same accent-tinted highlight shape as
      // ChannelMixBar's SideZone drop feedback.
      Rectangle {
        anchors.fill: parent
        anchors.margins: -Style.space(3)
        visible: reorderDropArea.containsDrag
        radius: Style.cornerRadius
        color: Style.hoverFillFor(root.fg, root.channelColor)
        border.width: Style.spacing.hairline
        border.color: root.channelColor
      }

      Row {
        id: headerRow
        spacing: Style.space(6)
      // Pinned rather than left to Row's automatic sizing: Row measures
      // every child's implicit size regardless of `visible`, and
      // TextInput's natural height (cursor/padding) is taller than a plain
      // Text's at the same font size — even hidden, it was inflating this
      // row a few px taller than MasterColumn's single-Text header,
      // throwing off every column's vertical alignment below it.
      height: headerLabel.implicitHeight

      // Draggable onto ChannelMixBar's side zones (see BarWidget.qml's
      // assignChannelMixSide) as well as clickable to open this channel's
      // EQ — same "wrap a fixed-position outer Item around a
      // drag.target-able inner one" shape as AppPill.qml (`slot`/
      // `pillRect`), needed because a bare `drag.target` on an item a
      // parent Row is actively positioning would fight the Row's own x/y
      // writes. `headerDragWrap` is what the Row lays out; `headerLabel`
      // inside it is what actually moves during a drag and always resets
      // to (0,0) — i.e. back to its Row-assigned position — on release.
      // `onClicked` and `drag.target` coexist natively on one MouseArea:
      // Qt only engages the drag past a small movement threshold, so a
      // plain click still opens the EQ view as before.
      Item {
        id: headerDragWrap
        visible: !root.editingName
        width: headerLabel.implicitWidth
        height: headerLabel.implicitHeight

        readonly property bool dragging: headerDragArea.drag.active

        onDraggingChanged: {
          if (!root.dragGhostRef) return
          if (headerDragWrap.dragging) {
            root.dragGhostRef.text = root.channelName.toUpperCase()
            root.dragGhostRef.accentColor = root.channelColor
            root.dragGhostRef.visible = true
            headerDragWrap._syncGhost()
          } else {
            root.dragGhostRef.visible = false
          }
        }

        function _syncGhost() {
          if (!root.dragGhostRef || !headerDragWrap.dragging) return
          var pos = headerLabel.mapToItem(root.dragGhostRef.parent, 0, 0)
          root.dragGhostRef.x = pos.x
          root.dragGhostRef.y = pos.y
        }

        Text {
          id: headerLabel
          text: root.channelName.toUpperCase()
          color: root.channelColor
          font.family: root.bar ? root.bar.fontFamily : undefined
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: 1
          opacity: (headerDragWrap.dragging && root.dragGhostRef) ? 0 : 1
          z: headerDragWrap.dragging ? 1000 : 0

          onXChanged: headerDragWrap._syncGhost()
          onYChanged: headerDragWrap._syncGhost()

          Drag.active: headerDragArea.drag.active
          Drag.source: root
          Drag.keys: ["channel"]
          Drag.hotSpot.x: width / 2
          Drag.hotSpot.y: height / 2

          MouseArea {
            id: headerDragArea
            anchors.fill: parent
            anchors.margins: -Style.space(4)
            drag.target: headerLabel
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.headerClicked()
            onReleased: {
              headerLabel.Drag.drop()
              headerLabel.x = 0
              headerLabel.y = 0
            }
          }
        }
      }

      TextInput {
        id: nameEdit
        visible: root.editingName
        text: root.channelName
        color: root.channelColor
        font.family: root.bar ? root.bar.fontFamily : undefined
        font.pixelSize: Style.font.caption
        font.bold: true
        width: Math.max(Style.space(56), implicitWidth + Style.space(4))
        anchors.verticalCenter: parent.verticalCenter
        onVisibleChanged: if (visible) { selectAll(); forceActiveFocus() }
        onAccepted: root._commitRename()
        onEditingFinished: root._commitRename()
        Keys.onEscapePressed: {
          nameEdit.text = root.channelName
          root.editingName = false
        }
      }

      Text {
        text: root.editingName ? "✓" : "✎"
        color: Qt.darker(root.fg, 1.4)
        font.family: root.bar ? root.bar.fontFamily : undefined
        font.pixelSize: Style.font.caption
        anchors.verticalCenter: parent.verticalCenter

        MouseArea {
          anchors.fill: parent
          anchors.margins: -Style.space(4)
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.editingName ? root._commitRename() : (root.editingName = true)
        }
      }

      Text {
        visible: !root.editingName
        text: "×"
        color: Qt.darker(root.fg, 1.6)
        font.family: root.bar ? root.bar.fontFamily : undefined
        font.pixelSize: Style.font.caption
        anchors.verticalCenter: parent.verticalCenter

        MouseArea {
          anchors.fill: parent
          anchors.margins: -Style.space(4)
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.deleteRequested()
        }
      }
    }

      // Reorder drop target: another channel's header dropped here moves
      // it to this channel's position (see BarWidget's
      // onChannelReorderRequested / ChannelManager.reorderChannel). Keyed
      // (rather than the bare property-presence check AppsDropZone/
      // ChannelMixBar use) so accurate hover feedback (containsDrag above)
      // doesn't also light up for an app pill being dragged past on its
      // way to this channel's Apps zone further down the column.
      DropArea {
        id: reorderDropArea
        anchors.fill: parent
        keys: ["channel"]
        onDropped: function(drop) {
          if (drop.source && drop.source.channelId && drop.source.channelId !== root.channelId)
            root.reorderRequested(drop.source.channelId)
        }
      }
    }

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: EqPresets.presetNameForIn(root.eq ? root.eq.presetId : "flat", root.presets)
      color: Qt.darker(root.fg, 1.4)
      font.family: root.bar ? root.bar.fontFamily : undefined
      font.pixelSize: Style.font.bodySmall
    }

    DeviceDropdown {
      anchors.horizontalCenter: parent.horizontalCenter
      width: parent.width
      bar: root.bar
      accentColor: root.channelColor
      deviceName: root.device
      devices: root.availableDevices
      expanded: root.dropdownOpen
      onDeviceSelected: function(deviceName) { root.deviceRequested(deviceName) }
      onToggleRequested: root.dropdownToggleRequested()
      onCloseRequested: root.dropdownCloseRequested()
    }

    Item { width: 1; height: Style.space(4) }

    ChannelFader {
      anchors.horizontalCenter: parent.horizontalCenter
      width: Style.space(30)
      height: Style.space(150)
      bar: root.bar
      value: root.volume
      peak: peakMonitor.peak
      accentColor: root.channelColor
      muted: root.muted
      opacity: !root.node ? 0.4 : 1.0
      enabled: !!root.node

      onMoved: function(v) { if (root.node && root.node.audio) root.node.audio.volume = v }
      onRightClicked: root.toggleMute()
    }

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: root.node ? Math.round(root.volume * 100) + "%" : "—"
      color: Qt.darker(root.fg, 1.5)
      font.family: root.bar ? root.bar.fontFamily : undefined
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      textFormat: Text.PlainText
      text: root.muted ? "󰝟" : "󰕾"
      color: root.fg
      font.family: root.bar ? root.bar.fontFamily : undefined
      font.pixelSize: Style.font.title
      opacity: (root.muted || !root.node) ? 0.5 : 1.0

      MouseArea {
        anchors.fill: parent
        enabled: !!root.node
        cursorShape: Qt.PointingHandCursor
        onClicked: root.toggleMute()
      }
    }

    Item { width: 1; height: Style.space(6) }

    AppsDropZone {
      width: parent.width
      height: Style.space(60)
      zoneId: root.channelId
      apps: root.apps
      dragGhostRef: root.dragGhostRef
      accentColor: root.channelColor
      placeholderText: root.node ? "" : "No sink yet"
      onAppDropped: function(streamNode, zoneId) { root.appDropped(streamNode, zoneId) }
    }
  }
}
