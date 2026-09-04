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
  property color addMicAccentColor: Color.accent
  // false only after a confirmed check finds lsp-plugins-lv2 missing (see
  // BarWidget._checkDependencies) — every channel's EQ depends on it, so
  // this warns up front rather than letting a channel silently roll back
  // ~8s after creation with nothing but a console.warn to explain why.
  property bool lspEqAvailable: true

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

    Rectangle {
      id: lspWarningBanner
      visible: !root.lspEqAvailable
      anchors.horizontalCenter: parent.horizontalCenter
      width: row.implicitWidth
      height: warningLabel.implicitHeight + Style.space(16)
      radius: Style.cornerRadius
      color: Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.12)
      border.width: Style.spacing.hairline
      border.color: Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.4)

      Text {
        id: warningLabel
        anchors.centerIn: parent
        width: parent.width - Style.space(24)
        wrapMode: Text.WordWrap
        horizontalAlignment: Text.AlignHCenter
        text: "⚠ lsp-plugins-lv2 not found — channels need it to process audio and will roll back a few seconds after creation. Install with: sudo pacman -S lsp-plugins-lv2, then reopen this panel."
        color: Color.urgent
        font.family: root.bar ? root.bar.fontFamily : undefined
        font.pixelSize: Style.font.bodySmall
      }
    }

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
        addMicAccentColor: root.addMicAccentColor
        onAppDropped: function(streamNode, zoneId) { root.appDropped(streamNode, zoneId) }
        onAddChannelRequested: function(type) { root.addChannelRequested(type) }
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
