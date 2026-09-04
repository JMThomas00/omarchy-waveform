import QtQuick
import qs.Commons

// ChannelMix — SteelSeries "ChatMix" generalized to any user-chosen group
// of channels on each side (renamed during the original design discussion,
// since it isn't limited to a chat channel). See BarWidget.qml's
// ChannelMix section for the gain model this drives: a channel's own fader
// is never touched, this only fades a separate, dedicated volume stage.
// Each side is a real drop zone — drag a channel's header (see
// ChannelColumn.qml) onto either side to assign it there; a channel can
// only be on one side at a time, so dragging it onto the other side moves
// it. Centered means neither side is affected; dragging toward one side
// fades it up and the other down.
Item {
  id: root

  property QtObject bar: null
  property var channelMixSideA: [] // [{id, name}, ...]
  property var channelMixSideB: []
  // Bound from outside (BarWidget owns the transient fade position) —
  // never mutated locally, same reason EqCurve's `bands`/ChannelFader's
  // `value` aren't: a MouseArea imperatively assigning a prop that's also
  // externally bound breaks that binding the first time it fires.
  property real t: 0

  signal balanceDragged(real t)
  // side: "a" | "b" | null (null = remove from ChannelMix entirely)
  signal assignRequested(string channelId, var side)

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property bool active: root.channelMixSideA.length > 0 && root.channelMixSideB.length > 0

  implicitWidth: column.implicitWidth
  implicitHeight: column.implicitHeight

  component SideZone: Rectangle {
    id: zone
    property string side: "a"
    property var members: []
    property alias dropArea: dropArea

    // No permanent box — just the chips/placeholder text floating directly
    // on the panel background, per feedback that the always-visible boxes
    // cluttered the view. Still shows a drop target during an active drag
    // (color only, no border) so the zone doesn't become undiscoverable —
    // the DropArea itself is unaffected either way, it's always live.
    radius: Style.cornerRadius
    color: dropArea.containsDrag ? Style.hoverFillFor(root.fg, Color.accent) : "transparent"

    Behavior on color { ColorAnimation { duration: 80 } }

    DropArea {
      id: dropArea
      anchors.fill: parent
      onDropped: function(drop) {
        if (drop.source && drop.source.channelId) root.assignRequested(drop.source.channelId, zone.side)
      }
    }

    // Side "a" (left) flows right-to-left so its chips hug the slider in
    // the middle instead of hugging the left edge — the two zones stay
    // visually close together as the panel widens with more channels,
    // rather than spreading toward the outer edges. Side "b" (right) is
    // already correct at the default left-to-right.
    Flow {
      anchors.fill: parent
      anchors.margins: Style.space(6)
      spacing: Style.space(4)
      layoutDirection: zone.side === "a" ? Qt.RightToLeft : Qt.LeftToRight

      Repeater {
        model: zone.members

        Rectangle {
          id: chip
          required property var modelData
          readonly property color chipColor: chip.modelData.color || Color.accent
          width: chipRow.implicitWidth + Style.space(12)
          height: chipRow.implicitHeight + Style.space(6)
          radius: Style.cornerRadius
          color: Qt.rgba(chip.chipColor.r, chip.chipColor.g, chip.chipColor.b, 0.18)
          border.width: Style.spacing.hairline
          border.color: chip.chipColor

          Row {
            id: chipRow
            anchors.centerIn: parent
            spacing: Style.space(4)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: chip.modelData.name.toUpperCase()
              color: chip.chipColor
              font.family: root.bar ? root.bar.fontFamily : undefined
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "×"
              color: Qt.darker(root.fg, 1.6)
              font.family: root.bar ? root.bar.fontFamily : undefined
              font.pixelSize: Style.font.caption

              MouseArea {
                anchors.fill: parent
                anchors.margins: -Style.space(4)
                cursorShape: Qt.PointingHandCursor
                onClicked: root.assignRequested(chip.modelData.id, null)
              }
            }
          }
        }
      }

      Text {
        visible: zone.members.length === 0
        text: ""
        color: Qt.darker(root.fg, 1.5)
        font.family: root.bar ? root.bar.fontFamily : undefined
        font.pixelSize: Style.font.caption
        font.italic: true
      }
    }
  }

  Column {
    id: column
    width: parent.width
    spacing: Style.space(6)

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: "CHANNELMIX"
      color: Qt.darker(root.fg, 1.6)
      font.family: root.bar ? root.bar.fontFamily : undefined
      font.pixelSize: Style.font.caption
      font.letterSpacing: 1
    }

    Row {
      id: zonesRow
      width: parent.width
      height: Style.space(40)
      spacing: Style.space(10)

      SideZone {
        width: (zonesRow.width - track.width - zonesRow.spacing * 2) / 2
        height: parent.height
        side: "a"
        members: root.channelMixSideA
      }

      Item {
        id: track
        width: Style.space(140)
        height: parent.height

        Rectangle {
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width
          height: Style.spacing.hairline * 2
          radius: height / 2
          color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, root.active ? 0.15 : 0.06)
        }

        Rectangle {
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.verticalCenter: parent.verticalCenter
          width: Style.spacing.hairline * 2
          height: Style.space(10)
          color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, root.active ? 0.3 : 0.1)
        }

        Rectangle {
          id: knob
          width: Style.space(14)
          height: width
          radius: width / 2
          x: (track.width - width) * ((root.t + 1) / 2)
          anchors.verticalCenter: parent.verticalCenter
          color: root.active ? Color.accent : Qt.darker(root.fg, 1.6)
          border.width: Style.spacing.hairline
          border.color: root.bar ? root.bar.background : Color.background
          scale: (knobArea.containsMouse || knobArea.pressed) ? 1.2 : 1.0

          Behavior on scale { NumberAnimation { duration: 100 } }
        }

        MouseArea {
          id: knobArea
          anchors.fill: parent
          anchors.margins: -Style.space(4)
          hoverEnabled: true
          enabled: root.active
          cursorShape: root.active ? Qt.PointingHandCursor : Qt.ArrowCursor

          function reportFromMouse(mouse) {
            var pos = knobArea.mapToItem(track, mouse.x, mouse.y)
            var t = (pos.x / track.width) * 2 - 1
            root.balanceDragged(Math.max(-1, Math.min(1, t)))
          }

          onPressed: function(mouse) { reportFromMouse(mouse) }
          onPositionChanged: function(mouse) { if (pressed) reportFromMouse(mouse) }
          onDoubleClicked: root.balanceDragged(0)
        }
      }

      SideZone {
        width: (zonesRow.width - track.width - zonesRow.spacing * 2) / 2
        height: parent.height
        side: "b"
        members: root.channelMixSideB
      }
    }
  }
}
