import QtQuick
import Quickshell.Services.Pipewire
import qs.Ui
import qs.Commons

// MASTER column — the computer's overall output volume (image #3, item 2).
Item {
  id: root

  property QtObject bar: null
  property var node: null
  property bool panelOpen: false
  property var apps: []
  property var dragGhostRef: null
  // Hashed off a fixed pseudo-id (see BarWidget.qml's channelColorFor) so
  // the "+ MIC" hover color is a real, theme-aware palette slot distinct
  // from Color.accent (which "+ OUT" hovers to) — deterministic and
  // consistent across restarts/theme switches, same mechanism a real
  // channel's own color uses.
  property color addMicAccentColor: Color.accent

  signal appDropped(var streamNode, string zoneId)
  // "output" | "input" — see MixerView.qml's own addChannelRequested,
  // which this just forwards. Lives here (not in the trailing standalone
  // column MixerView used to render past the last channel) so MASTER's
  // otherwise-empty EQ-name/device-name rows do double duty as the add
  // buttons, keeping the whole mixer symmetric: MASTER + N real channels,
  // no dangling extra column throwing off the row's overall centering.
  signal addChannelRequested(string type)

  readonly property real volume: node && node.audio ? node.audio.volume : 0
  readonly property bool muted: node && node.audio ? node.audio.muted : false
  readonly property color fg: bar ? bar.foreground : Color.foreground

  function toggleMute() {
    if (node && node.audio) node.audio.muted = !node.audio.muted
  }

  implicitWidth: column.implicitWidth
  implicitHeight: column.implicitHeight

  PwNodePeakMonitor {
    id: peakMonitor
    node: root.node
    enabled: root.panelOpen && !!root.node
  }

  Column {
    id: column
    // Matches ChannelColumn's own width exactly (was Style.space(84), a
    // stale narrower value from before ChannelColumn widened 96->116 for
    // the device-dropdown/app-pill legibility fix) — a mismatched width
    // here doesn't break any single row's internal centering (every child
    // already centers itself within whatever width `column` has), but it
    // does throw off the row of boxes below the faders (Apps zone, and
    // this column's own "+ MIC" button) relative to the matching boxes in
    // every ChannelColumn, since equal Row spacing
    // between differently-sized columns doesn't produce equal box-edge
    // alignment even though each column's own contents stay centered.
    width: Style.space(116)
    // Matches ChannelColumn's spacing/row heights exactly (including this
    // invisible placeholder standing in for its "Flat" EQ-preset line) so
    // both columns' Apps zones land on the same row — MASTER doesn't have
    // an EQ preset of its own, but needs the identical vertical rhythm
    // above the fader for the layouts to line up.
    spacing: Style.space(6)

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: "MASTER"
      color: root.fg
      font.family: root.bar ? root.bar.fontFamily : undefined
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1
      opacity: 0.85
    }

    // Sits in the same row ChannelColumn uses for its EQ preset name.
    // MASTER has no EQ preset of its own, so this row is free to be the
    // "+ OUT" add-channel button instead of an inert placeholder.
    AddChannelButton {
      anchors.horizontalCenter: parent.horizontalCenter
      label: "+ OUT"
      pixelSize: Style.font.bodySmall
      idleColor: root.fg
      hoverColor: Color.accent
      fontFamily: root.bar ? root.bar.fontFamily : ""
      onClicked: root.addChannelRequested("output")
    }

    // Same row ChannelColumn uses for its DeviceDropdown — MASTER has no
    // device to pick, so this row is the "+ MIC" add-channel button
    // instead. `verticalPadding: Style.space(6)` matches DeviceDropdown's
    // own trigger-height formula so this row's height still lines up.
    // Hovers to a different theme color than "+ OUT" (which hovers to
    // Color.accent) so the two read as distinct actions.
    AddChannelButton {
      anchors.horizontalCenter: parent.horizontalCenter
      label: "+ MIC"
      pixelSize: Style.font.caption
      verticalPadding: Style.space(6)
      idleColor: root.fg
      hoverColor: root.addMicAccentColor
      fontFamily: root.bar ? root.bar.fontFamily : ""
      onClicked: root.addChannelRequested("input")
    }

    Item { width: 1; height: Style.space(4) }

    // Same height as a channel's fader (see ChannelColumn) — required for
    // the Apps zones below to align; MASTER doesn't get a taller fader.
    ChannelFader {
      anchors.horizontalCenter: parent.horizontalCenter
      width: Style.space(30)
      height: Style.space(150)
      bar: root.bar
      value: root.volume
      peak: peakMonitor.peak
      accentColor: Color.accent
      muted: root.muted

      onMoved: function(v) { if (root.node && root.node.audio) root.node.audio.volume = v }
      onRightClicked: root.toggleMute()
    }

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: Math.round(root.volume * 100) + "%"
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
      opacity: root.muted ? 0.5 : 1.0

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: root.toggleMute()
      }
    }

    Item { width: 1; height: Style.space(6) }

    // Apps not yet dragged into a channel land here — "Apps to be routed",
    // matching image #3's MASTER column. Dragging one out (to a channel)
    // or back in here routes it to/from the system default sink.
    AppsDropZone {
      width: parent.width
      height: Style.space(60)
      zoneId: "master"
      apps: root.apps
      dragGhostRef: root.dragGhostRef
      accentColor: Color.accent
      placeholderText: ""
      onAppDropped: function(streamNode, zoneId) { root.appDropped(streamNode, zoneId) }
    }
  }
}
