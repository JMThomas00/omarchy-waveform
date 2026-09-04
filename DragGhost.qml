import QtQuick
import qs.Commons

// A single shared, unclipped visual stand-in for whichever AppPill is
// currently being dragged. AppsDropZone's Apps box now scrolls (ScrollView,
// clip: true) so a channel with many apps doesn't overflow — but that same
// clip silently hides the real pill the instant a drag carries it outside
// its own zone's box. This ghost lives at MixerView's root (never clipped)
// and mirrors the real pill's position/label/color while dragging; the
// real pill hides itself and hands off to this instead. See AppPill.qml.
Rectangle {
  id: ghost

  property alias text: label.text
  property color accentColor: Color.accent

  visible: false
  z: 10000

  width: label.implicitWidth + Style.space(14)
  height: label.implicitHeight + Style.space(8)
  radius: Style.cornerRadius
  color: Qt.rgba(accentColor.r, accentColor.g, accentColor.b, 0.4)
  border.width: Style.spacing.hairline
  border.color: accentColor

  Text {
    id: label
    anchors.centerIn: parent
    color: Color.foreground
    font.pixelSize: Style.font.caption
    elide: Text.ElideRight
  }
}
