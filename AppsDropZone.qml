import QtQuick
import QtQuick.Controls
import qs.Commons
import "AppsModel.js" as AppsModel

// Drop target for one channel (or MASTER's "unrouted" zone) — image #3's
// item 5. Apps currently connected to that zone's sink render as
// draggable AppPill rows; dropping one from elsewhere calls
// RoutingManager.routeStream via the appDropped signal, threaded up through
// MixerView to BarWidget, which resolves it.
Rectangle {
  id: zone

  property string zoneId: ""
  property var apps: []
  property color accentColor: Color.accent
  property string placeholderText: "Apps"
  property var dragGhostRef: null

  signal appDropped(var streamNode, string zoneId)

  radius: Style.cornerRadius
  color: dropArea.containsDrag
    ? Style.hoverFillFor(Color.foreground, zone.accentColor)
    : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.05)
  border.width: Style.spacing.hairline
  border.color: dropArea.containsDrag
    ? zone.accentColor
    : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.12)

  Behavior on color { ColorAnimation { duration: 80 } }

  DropArea {
    id: dropArea
    anchors.fill: parent
    onDropped: function(drop) {
      if (drop.source && drop.source.node) zone.appDropped(drop.source.node, zone.zoneId)
    }
  }

  // Every channel's Apps zone stays the same fixed size regardless of how
  // many apps land in it — a scrollable Flow inside, rather than growing
  // the box or truncating/hiding pills a drag might target.
  ScrollView {
    anchors.fill: parent
    anchors.margins: Style.space(6)
    clip: true
    ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

    Flow {
      width: zone.width - Style.space(12)
      spacing: Style.space(4)

      Repeater {
        model: zone.apps
        AppPill {
          required property var modelData
          node: modelData
          label: AppsModel.streamLabel(modelData)
          accentColor: zone.accentColor
          dragGhostRef: zone.dragGhostRef
        }
      }
    }
  }

  Text {
    visible: zone.apps.length === 0
    anchors.centerIn: parent
    text: zone.placeholderText
    color: Qt.darker(Color.foreground, 1.6)
    font.pixelSize: Style.font.caption
    font.italic: true
  }
}
