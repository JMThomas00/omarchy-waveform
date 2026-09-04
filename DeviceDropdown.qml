import QtQuick
import qs.Commons

// Compact device picker shown under a channel's EQ-preset label (image #15
// in the original design discussion — Sonar's own per-channel device row).
// `devices` is the live list of real PwNode devices this channel could
// target (output sinks for an output channel, input sources for an input
// channel — see BarWidget.realOutputDevices/realInputDevices) — deliberately
// NOT routed through any stable-snapshot freeze, so a device that connects
// while the list is open (Bluetooth headphones pairing, say) appears
// without needing to close and reopen it.
//
// The expanded list renders as a child positioned below the trigger with a
// high z rather than a DragGhost-style shared unclipped overlay: nothing
// up the tree here clips (confirmed — MixerView/ChannelColumn/BorderSurface
// none of them set `clip: true`), and the list only ever needs to paint
// over content *below* it in this same channel's own column (the fader,
// the apps zone) — a plain z-index is enough for that, no cross-column
// reparenting needed. Keeping `implicitHeight` fixed to just the trigger's
// height (not including the expanded list) matters just as much: the list
// is absolutely positioned, not part of the parent Column's normal flow,
// so opening it never pushes the fader/apps zone down.
//
// `z` has to be raised at EVERY level between the list and whatever it
// needs to paint over, not just on the list itself — confirmed directly,
// the hard way: the list's own internal `z: 1000` only wins against ITS
// sibling (the trigger) inside this component; `ChannelFader` is a sibling
// of this whole `DeviceDropdown`, one level further up in ChannelColumn's
// own layout, and kept painting on top regardless, since a nested child's
// z-value doesn't propagate past its own parent's stacking context. This
// root `Item` needs the same boost too — see `z` below, and
// ChannelColumn.qml's matching boost on itself for the same reason at the
// next level up (a wide dropdown can spill into a neighboring column).
Item {
  id: root

  z: root.expanded ? 1000 : 0

  property QtObject bar: null
  property color accentColor: Color.accent
  property string deviceName: "" // this channel's target device's raw node.name
  property var devices: [] // live PwNode list

  signal deviceSelected(string deviceName)

  readonly property color fg: bar ? bar.foreground : Color.foreground

  function _labelFor(node) {
    if (!node) return ""
    return String(node.description || node.nickname || node.name || "")
  }

  readonly property var _selectedNode: {
    for (var i = 0; i < root.devices.length; i++)
      if (String(root.devices[i].name) === root.deviceName) return root.devices[i]
    return null
  }
  readonly property string _selectedLabel: root._selectedNode ? root._labelFor(root._selectedNode) : (root.deviceName || "No device")

  // Bound from outside (BarWidget owns which single channel's dropdown, if
  // any, is currently open — see openDeviceDropdownChannelId) rather than
  // toggled locally, so opening one always closes any other that was open.
  property bool expanded: false

  signal toggleRequested()
  signal closeRequested()

  implicitWidth: Style.space(96)
  implicitHeight: trigger.implicitHeight

  Rectangle {
    id: trigger
    width: parent.width
    implicitHeight: label.implicitHeight + Style.space(6)
    radius: Style.cornerRadius
    color: triggerArea.containsMouse ? Style.hoverFillFor(root.fg, root.accentColor) : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.05)
    border.width: Style.spacing.hairline
    border.color: root.expanded ? root.accentColor : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.12)

    Text {
      id: label
      anchors.centerIn: parent
      width: parent.width - Style.space(8)
      horizontalAlignment: Text.AlignHCenter
      elide: Text.ElideRight
      text: root._selectedLabel
      color: Qt.darker(root.fg, 1.3)
      font.family: root.bar ? root.bar.fontFamily : undefined
      font.pixelSize: Style.font.caption
    }

    MouseArea {
      id: triggerArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.toggleRequested()
    }
  }

  // Click-outside-to-close: a screen-spanning catcher behind the list,
  // only present while expanded.
  MouseArea {
    visible: root.expanded
    parent: root.QsWindow && root.QsWindow.window ? root.QsWindow.window.contentItem : root
    anchors.fill: parent
    z: 999
    onClicked: root.closeRequested()
  }

  Rectangle {
    id: listBox
    visible: root.expanded
    z: 1000
    anchors.top: trigger.bottom
    anchors.topMargin: Style.space(4)
    x: 0
    width: Math.max(root.width, Style.space(150))
    height: Math.min(listColumn.implicitHeight + Style.space(8), Style.space(220))
    radius: Style.cornerRadius
    color: root.bar ? root.bar.background : Color.background
    border.width: Style.spacing.hairline
    border.color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.18)
    clip: true

    Flickable {
      anchors.fill: parent
      anchors.margins: Style.space(4)
      contentWidth: width
      contentHeight: listColumn.implicitHeight
      clip: true

      Column {
        id: listColumn
        width: parent.width

        Repeater {
          model: root.devices

          Rectangle {
            id: row
            required property var modelData
            width: listColumn.width
            height: rowLabel.implicitHeight + Style.space(8)
            radius: Style.cornerRadius
            readonly property bool selected: String(modelData.name) === root.deviceName
            color: row.selected
              ? Style.selectedFillFor(root.fg, root.accentColor)
              : (rowArea.containsMouse ? Style.hoverFillFor(root.fg, root.accentColor) : "transparent")

            Text {
              id: rowLabel
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.leftMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              elide: Text.ElideRight
              text: root._labelFor(row.modelData)
              color: row.selected ? root.accentColor : root.fg
              font.family: root.bar ? root.bar.fontFamily : undefined
              font.pixelSize: Style.font.caption
              font.bold: row.selected
            }

            MouseArea {
              id: rowArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                root.deviceSelected(String(row.modelData.name))
                root.closeRequested()
              }
            }
          }
        }

        Text {
          visible: root.devices.length === 0
          width: listColumn.width
          horizontalAlignment: Text.AlignHCenter
          text: "No devices found"
          color: Qt.darker(root.fg, 1.5)
          font.family: root.bar ? root.bar.fontFamily : undefined
          font.pixelSize: Style.font.caption
          font.italic: true
        }
      }
    }
  }
}
