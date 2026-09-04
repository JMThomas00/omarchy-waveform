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
