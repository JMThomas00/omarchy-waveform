import QtQuick
import qs.Commons

// Mixer landing view: MASTER + one column per channel, side by side —
// matches Sonar's mixer layout (image #3 in the original design discussion).
Item {
  id: root

  property QtObject bar: null
  property var masterSink: null
  property bool panelOpen: false
  property var channels: []
  property var masterApps: []
  property var presets: []
  property var channelMixSideA: []
  property var channelMixSideB: []
  property real channelMixT: 0
  property var realOutputDevices: []
  property var realInputDevices: []
  property string openDeviceDropdownChannelId: ""

  signal channelHeaderClicked(string channelId)
  signal addChannelRequested(string type)
  signal channelDeleteRequested(string channelId)
  signal channelRenameRequested(string channelId, string newName)
  signal appDropped(var streamNode, string zoneId)
  signal channelMixBalanceDragged(real t)
  signal channelMixAssignRequested(string channelId, var side)
  signal channelDeviceRequested(string channelId, string deviceName)
  signal deviceDropdownToggleRequested(string channelId)
  signal deviceDropdownCloseRequested()
  signal channelReorderRequested(string draggedChannelId, string targetChannelId)

  implicitWidth: layout.implicitWidth + Style.space(28)
  implicitHeight: layout.implicitHeight + Style.space(28)

  // Unclipped drag-visual layer — see DragGhost.qml and AppPill.qml. Lives
  // directly on `root` (not inside `row`) so mapping any pill's position
  // into `dragGhost.parent`'s coordinate space places it correctly
  // regardless of which column's (clipped) Apps box the drag started in.
  DragGhost { id: dragGhost }
  // Exposed so BarWidget can tell whether any pill anywhere is actively
  // being dragged right now (dragGhost.visible) and freeze its
  // Repeater-feeding snapshots for the duration — see BarWidget.qml's
  // dragInProgress/displayChannels.
  property alias exposedDragGhost: dragGhost

  Column {
    id: layout
    anchors.centerIn: parent
    spacing: Style.space(16)

    Row {
      id: row
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: Style.space(18)

      MasterColumn {
        bar: root.bar
        node: root.masterSink
        panelOpen: root.panelOpen
        apps: root.masterApps
        dragGhostRef: dragGhost
        onAppDropped: function(streamNode, zoneId) { root.appDropped(streamNode, zoneId) }
      }

      Repeater {
        model: root.channels

        ChannelColumn {
          required property var modelData
          bar: root.bar
          channelId: modelData.id
          channelName: modelData.name
          channelType: modelData.type
          device: modelData.device
          node: modelData.node
          outputNode: modelData.outputNode
          panelOpen: root.panelOpen
          apps: modelData.apps || []
          eq: modelData.eq
          channelColor: modelData.color
          presets: root.presets
          availableDevices: modelData.type === "input" ? root.realInputDevices : root.realOutputDevices
          dragGhostRef: dragGhost
          dropdownOpen: root.openDeviceDropdownChannelId === modelData.id
          onHeaderClicked: root.channelHeaderClicked(modelData.id)
          onDeleteRequested: root.channelDeleteRequested(modelData.id)
          onRenameRequested: function(newName) { root.channelRenameRequested(modelData.id, newName) }
          onAppDropped: function(streamNode, zoneId) { root.appDropped(streamNode, zoneId) }
          onDeviceRequested: function(deviceName) { root.channelDeviceRequested(modelData.id, deviceName) }
          onDropdownToggleRequested: root.deviceDropdownToggleRequested(modelData.id)
          onDropdownCloseRequested: root.deviceDropdownCloseRequested()
          onReorderRequested: function(draggedChannelId) { root.channelReorderRequested(draggedChannelId, modelData.id) }
        }
      }

      // Creates a real channel: persistent virtual sink/source + hosted
      // filter-chain client + systemd --user unit (see ChannelManager.qml).
      // Two affordances, not one — output (apps play into it) and input
      // (captures from a real mic, exposes the EQ'd result as a virtual
      // mic other apps can pick) render as genuinely different filter-chain
      // shapes (FilterChainGen.renderOutputRouting/renderInputRouting),
      // so the type has to be chosen at creation, not toggled after.
      // Top-aligned (matching every channel header's own y:0, rather than
      // vertically centered in the Row) instead of the previous fix's extra
      // horizontal spacer: sitting up here is clear of the device dropdown
      // area entirely regardless of how wide a long device list gets, no
      // dedicated gap needed to avoid it.
      Column {
        anchors.top: parent.top
        spacing: Style.space(8)

        // Height still matches a channel's own (collapsed) device-dropdown
        // trigger (label height + Style.space(6), same formula
        // DeviceDropdown.qml's own `trigger` uses) — width was briefly
        // matched to a full channel column too (to rule out the last
        // channel's dropdown overlapping these buttons) but that's not
        // actually what fixed it: this Column is the last child in `row`,
        // so its own width only affects where *its* right edge (and the
        // panel's total content width) lands, never its left edge/position
        // relative to the channel before it — narrower here doesn't bring
        // back the overlap.
        Rectangle {
          width: Style.space(64)
          height: outLabel.implicitHeight + Style.space(6)
          radius: Style.cornerRadius
          color: addOutputArea.containsMouse ? Style.hoverFillFor(root.bar ? root.bar.foreground : Color.foreground, Color.accent) : "transparent"
          border.width: Style.spacing.hairline
          border.color: Qt.rgba(root.bar ? root.bar.foreground.r : Color.foreground.r, root.bar ? root.bar.foreground.g : Color.foreground.g, root.bar ? root.bar.foreground.b : Color.foreground.b, 0.12)

          Text {
            id: outLabel
            anchors.centerIn: parent
            text: "+ OUT"
            color: root.bar ? root.bar.foreground : Color.foreground
            font.family: root.bar ? root.bar.fontFamily : undefined
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          MouseArea {
            id: addOutputArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.addChannelRequested("output")
          }
        }

        Rectangle {
          width: Style.space(64)
          height: micLabel.implicitHeight + Style.space(6)
          radius: Style.cornerRadius
          color: addInputArea.containsMouse ? Style.hoverFillFor(root.bar ? root.bar.foreground : Color.foreground, Color.accent) : "transparent"
          border.width: Style.spacing.hairline
          border.color: Qt.rgba(root.bar ? root.bar.foreground.r : Color.foreground.r, root.bar ? root.bar.foreground.g : Color.foreground.g, root.bar ? root.bar.foreground.b : Color.foreground.b, 0.12)

          Text {
            id: micLabel
            anchors.centerIn: parent
            text: "+ MIC"
            color: root.bar ? root.bar.foreground : Color.foreground
            font.family: root.bar ? root.bar.fontFamily : undefined
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          MouseArea {
            id: addInputArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.addChannelRequested("input")
          }
        }
      }
    }

    ChannelMixBar {
      width: row.implicitWidth
      bar: root.bar
      channelMixSideA: root.channelMixSideA
      channelMixSideB: root.channelMixSideB
      t: root.channelMixT
      onBalanceDragged: function(t) { root.channelMixBalanceDragged(t) }
      onAssignRequested: function(channelId, side) { root.channelMixAssignRequested(channelId, side) }
    }
  }
}
