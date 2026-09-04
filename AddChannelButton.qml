import QtQuick
import qs.Commons

// Plain-text, no-background "+ OUT"/"+ MIC" affordance — MasterColumn's two
// instances of this stand in for ChannelColumn's EQ-preset-name row and
// DeviceDropdown's trigger row respectively (MASTER has neither of its own),
// so each instance's `pixelSize`/`verticalPadding` must exactly match the row
// it's pixel-aligned to, or MASTER drifts out of alignment with every real
// channel column below the header — this file's own history already hit that
// exact regression twice from two separate causes. Deliberately never bold,
// even though it'd look more "buttony": both rows this stands in for (the EQ
// preset name, DeviceDropdown's trigger label) are plain-weight, and a bold
// face's line metrics aren't guaranteed identical to its regular face's,
// which would silently reintroduce the same misalignment a third time.
Item {
  id: root

  property string label: ""
  property real pixelSize: Style.font.bodySmall
  // Extra height added below the text's own line height — 0 to exactly
  // match a plain preset-name row, Style.space(6) to match a
  // DeviceDropdown trigger row (see DeviceDropdown.qml's own `trigger`).
  property real verticalPadding: 0
  property color idleColor: Color.foreground
  property color hoverColor: Color.accent
  property string fontFamily: ""

  signal clicked()

  width: labelText.implicitWidth
  height: labelText.implicitHeight + root.verticalPadding

  Text {
    id: labelText
    anchors.centerIn: parent
    text: root.label
    color: hitArea.containsMouse ? root.hoverColor : Qt.darker(root.idleColor, 1.4)
    font.family: root.fontFamily || undefined
    font.pixelSize: root.pixelSize
  }

  MouseArea {
    id: hitArea
    anchors.fill: parent
    // Horizontal-only expansion: these two buttons stack directly above
    // each other with only Style.space(6) between them (MasterColumn's
    // Column spacing) — expanding vertically too would overlap the
    // neighboring button's own hit area in that gap and could catch a
    // click meant for the other one.
    anchors.leftMargin: -Style.space(4)
    anchors.rightMargin: -Style.space(4)
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.clicked()
  }
}
