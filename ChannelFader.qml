import QtQuick
import qs.Commons

// Vertical fader shared by MASTER and every channel column. Built natively
// rather than as a rotated qs.Ui PanelSlider (M1-M3's approach) so the live
// peak-level meter can be the dominant, on-top visual — per user feedback,
// PanelSlider's own big "set volume" fill was competing with/burying the
// meter, backwards from what actually matters moment-to-moment: the knob
// position alone already communicates the set volume, so there's no need
// for a second competing fill bar.
Item {
  id: root

  property QtObject bar: null
  property real value: 0   // 0..1, the set volume
  property real peak: 0    // 0..1, live level
  property color accentColor: Color.accent
  property bool muted: false
  property real minimum: 0
  property real maximum: 1

  signal moved(real value)
  signal rightClicked()

  property bool dragging: false
  property real liveValue: value
  onValueChanged: if (!root.dragging) root.liveValue = value

  readonly property real range: Math.max(0.0001, maximum - minimum)
  readonly property real progress: Math.max(0, Math.min(1, (liveValue - minimum) / range))

  implicitWidth: Style.space(30)

  readonly property real trackWidth: Math.max(4, Style.space(6))

  // Thin neutral track, full height.
  Rectangle {
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    width: root.trackWidth
    radius: width / 2
    color: Style.selectedFillFor(root.bar ? root.bar.foreground : Color.foreground, Color.accent)
  }

  // Live level meter — the dominant visual, painted over the track.
  Rectangle {
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    width: root.trackWidth
    radius: width / 2
    color: root.accentColor
    opacity: root.muted ? 0.25 : 0.85
    height: parent.height * Math.max(0, Math.min(1, root.peak))

    Behavior on height {
      NumberAnimation { duration: 60 }
    }
  }

  // Marks the set volume — no separate fill bar to compete with the meter
  // above; the knob position alone communicates the set level.
  Rectangle {
    id: knob
    width: Math.max(14, Style.space(16))
    height: width
    radius: width / 2
    color: root.bar ? root.bar.foreground : Color.foreground
    border.width: Math.max(1, Style.space(2))
    border.color: root.bar ? root.bar.background : Color.background
    anchors.horizontalCenter: parent.horizontalCenter
    y: (parent.height - height) * (1 - root.progress)
    scale: (mouseArea.containsMouse || root.dragging) ? 1.15 : 1.0

    Behavior on y {
      enabled: !root.dragging
      NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
    }
    Behavior on scale {
      NumberAnimation { duration: 110; easing.type: Easing.OutCubic }
    }
  }

  MouseArea {
    id: mouseArea
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton

    function valueFromY(y) {
      var clamped = Math.max(0, Math.min(root.height, y))
      var raw = root.maximum - (clamped / root.height) * root.range
      return Math.max(root.minimum, Math.min(root.maximum, raw))
    }

    onPressed: function(mouse) {
      if (mouse.button !== Qt.LeftButton) return
      root.dragging = true
      var next = valueFromY(mouse.y)
      root.liveValue = next
      root.moved(next)
    }
    onClicked: function(mouse) {
      if (mouse.button === Qt.RightButton) root.rightClicked()
    }
    onPositionChanged: function(mouse) {
      if (!root.dragging) return
      var next = valueFromY(mouse.y)
      root.liveValue = next
      root.moved(next)
    }
    onReleased: function(mouse) {
      if (mouse.button !== Qt.LeftButton) return
      root.dragging = false
      root.liveValue = root.value
    }
    onWheel: function(wheel) {
      var delta = wheel.angleDelta.y > 0 ? 0.05 : -0.05
      var next = Math.max(root.minimum, Math.min(root.maximum, root.liveValue + delta))
      root.liveValue = next
      root.moved(next)
    }
  }
}
