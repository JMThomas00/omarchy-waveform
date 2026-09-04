import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "EqBands.js" as EqBands
import "ThemePaletteGen.js" as ThemePaletteGen

// Interactive EQ curve (image #1's target layout) — 6 draggable band points
// connected by a line, -12..+12 dB. Each handle's position is a pure
// binding off `bands[index]`, never imperatively assigned by the drag
// itself (that's what ChannelFader's knob does too, for the same reason):
// MouseArea's `drag.target` would otherwise silently break the binding the
// first time a point is dragged, leaving it unable to follow `bands`
// reactively afterward (e.g. when a preset is selected instead of a manual
// drag). Dragging instead maps the pointer position into this Item's own
// coordinate space and emits `bandDragged`; the caller updates `bands` and
// the binding moves the handle.
Item {
  id: root

  property var bands: EqBands.flatBands()
  property color accentColor: Color.accent
  property QtObject bar: null

  // Live per-bar levels (0..1), one entry per bar — see EqView.qml's cava
  // process. Independent of `bandCount`/`bands`: this is a much finer-
  // grained spectrum (see EqView's spectrumBarCount) drawn as a smooth
  // filled silhouette behind the curve, not aligned point-for-point with
  // the 6 draggable EQ bands.
  property var spectrumLevels: []
  property color spectrumColor: Color.accent

  // Multi-color spectrum fill: the active theme's vivid named colors (red/
  // yellow/orange/green/cyan/blue/magenta/brown + their bright_ variants —
  // confirmed present in every shipped theme's colors.toml, see
  // ThemePaletteGen.js), sorted darkest -> lightest and painted
  // left-to-right across the spectrum's frequency axis (bass is
  // low-index/left, treble is high-index/right — same direction cava's bars
  // and EqBands.BANDS already use). Read once per theme load/switch
  // (watchChanges: true, same as Color.qml's own colors.toml FileView) —
  // not per-channel, this isn't the M6 hashing work, just borrowing its
  // color source for this one view.
  readonly property string _themeColorsPath: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"
  property var _paletteHex: []
  readonly property var spectrumPalette: {
    if (root._paletteHex.length >= 2) return root._paletteHex.map(function(h) { return Qt.color(h) })
    // Fallback if the theme file is missing/unreadable or too sparse: two
    // tones of the one theme color already piped into Waveform.
    return [Qt.darker(root.spectrumColor, 1.7), Qt.lighter(root.spectrumColor, 1.6)]
  }

  FileView {
    path: root._themeColorsPath
    watchChanges: true
    printErrors: false
    onLoaded: root._paletteHex = ThemePaletteGen.parseSortedPalette(text())
    onFileChanged: reload()
  }

  signal bandDragged(int index, real db)

  readonly property int bandCount: EqBands.BANDS.length
  readonly property real minDb: EqBands.MIN_DB
  readonly property real maxDb: EqBands.MAX_DB
  readonly property color fg: bar ? bar.foreground : Color.foreground

  function bandValue(i) {
    return (root.bands && root.bands[i] !== undefined) ? root.bands[i] : 0
  }
  function xForIndex(i) {
    return (i + 0.5) * (plotArea.width / root.bandCount)
  }
  function yForDb(db) {
    var t = (db - root.minDb) / (root.maxDb - root.minDb)
    return plotArea.height - t * plotArea.height
  }
  function dbForY(y) {
    var clamped = Math.max(0, Math.min(plotArea.height, y))
    var t = 1 - clamped / plotArea.height
    return EqBands.clampDb(root.minDb + t * (root.maxDb - root.minDb))
  }

  Column {
    anchors.fill: parent
    spacing: Style.space(4)

    Item {
      id: plotArea
      width: parent.width
      height: parent.height - bandLabels.height - Style.space(8)

      Rectangle {
        anchors.fill: parent
        radius: Style.cornerRadius
        color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.04)
        border.width: Style.spacing.hairline
        border.color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.12)
      }

      Repeater {
        model: [-12, -6, 0, 6, 12]
        Rectangle {
          required property var modelData
          y: root.yForDb(modelData)
          width: plotArea.width
          height: modelData === 0 ? Style.spacing.hairline * 2 : Style.spacing.hairline
          color: root.fg
          opacity: modelData === 0 ? 0.3 : 0.12
        }
      }

      Canvas {
        id: spectrumCanvas
        anchors.fill: parent
        property var watchedLevels: root.spectrumLevels
        property var watchedPalette: root.spectrumPalette
        onWatchedLevelsChanged: requestPaint()
        onWatchedPaletteChanged: requestPaint()
        onPaint: {
          var ctx = getContext("2d")
          ctx.reset()
          var levels = root.spectrumLevels
          var n = levels ? levels.length : 0
          if (n < 2) return
          var w = width, h = height
          function px(i) { return (i + 0.5) * (w / n) }
          function py(i) { return h - Math.max(0, Math.min(1, levels[i])) * h }

          ctx.beginPath()
          ctx.moveTo(0, h)
          ctx.lineTo(px(0), py(0))
          for (var i = 1; i < n; i++) {
            var midX = (px(i - 1) + px(i)) / 2
            var midY = (py(i - 1) + py(i)) / 2
            ctx.quadraticCurveTo(px(i - 1), py(i - 1), midX, midY)
          }
          ctx.lineTo(px(n - 1), py(n - 1))
          ctx.lineTo(w, h)
          ctx.closePath()

          // Pass 1: fill the silhouette with a horizontal gradient across
          // the theme palette, dark (bass, left) -> light (treble, right).
          var palette = root.spectrumPalette
          var hgrad = ctx.createLinearGradient(0, 0, w, 0)
          for (var p = 0; p < palette.length; p++) {
            var c = palette[p]
            var stop = palette.length === 1 ? 0 : p / (palette.length - 1)
            hgrad.addColorStop(stop, Qt.rgba(c.r, c.g, c.b, 0.6))
          }
          ctx.fillStyle = hgrad
          ctx.fill()

          // Pass 2: mask that fill with a vertical top-opaque ->
          // bottom-transparent gradient so it still reads as a "rising"
          // waveform rather than a flat-colored block, regardless of hue.
          ctx.save()
          ctx.globalCompositeOperation = "destination-in"
          var vgrad = ctx.createLinearGradient(0, 0, 0, h)
          vgrad.addColorStop(0, Qt.rgba(1, 1, 1, 1))
          vgrad.addColorStop(1, Qt.rgba(1, 1, 1, 0))
          ctx.fillStyle = vgrad
          ctx.fillRect(0, 0, w, h)
          ctx.restore()
        }
      }

      Canvas {
        id: curveCanvas
        anchors.fill: parent
        property var watchedBands: root.bands
        onWatchedBandsChanged: requestPaint()
        onPaint: {
          var ctx = getContext("2d")
          ctx.reset()
          ctx.strokeStyle = root.accentColor
          ctx.lineWidth = Style.space(2)
          ctx.lineJoin = "round"
          ctx.beginPath()
          for (var i = 0; i < root.bandCount; i++) {
            var x = root.xForIndex(i)
            var y = root.yForDb(root.bandValue(i))
            if (i === 0) ctx.moveTo(x, y)
            else ctx.lineTo(x, y)
          }
          ctx.stroke()
        }
      }

      Repeater {
        model: root.bandCount

        Item {
          id: handleWrap
          required property int index
          readonly property real db: root.bandValue(index)
          x: root.xForIndex(index) - width / 2
          y: root.yForDb(db) - height / 2
          width: Style.space(16)
          height: width

          Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: root.accentColor
            border.width: Style.spacing.hairline
            border.color: root.bar ? root.bar.background : Color.background
            scale: (dragArea.containsMouse || dragArea.pressed) ? 1.25 : 1.0

            Behavior on scale { NumberAnimation { duration: 100 } }
          }

          Text {
            visible: dragArea.containsMouse || dragArea.pressed
            anchors.bottom: parent.top
            anchors.bottomMargin: Style.space(4)
            anchors.horizontalCenter: parent.horizontalCenter
            text: (handleWrap.db > 0 ? "+" : "") + handleWrap.db.toFixed(1) + " dB"
            color: root.fg
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          MouseArea {
            id: dragArea
            anchors.fill: parent
            anchors.margins: -Style.space(6)
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor

            function reportFromMouse(mouse) {
              var posInPlot = dragArea.mapToItem(plotArea, mouse.x, mouse.y)
              root.bandDragged(handleWrap.index, root.dbForY(posInPlot.y))
            }

            onPressed: function(mouse) { reportFromMouse(mouse) }
            onPositionChanged: function(mouse) { if (pressed) reportFromMouse(mouse) }
            onWheel: function(wheel) {
              var delta = wheel.angleDelta.y > 0 ? 0.5 : -0.5
              root.bandDragged(handleWrap.index, EqBands.clampDb(handleWrap.db + delta))
            }
          }
        }
      }
    }

    Row {
      id: bandLabels
      width: parent.width
      Repeater {
        model: EqBands.BANDS
        Text {
          required property var modelData
          width: bandLabels.width / root.bandCount
          horizontalAlignment: Text.AlignHCenter
          text: modelData.label
          color: Qt.darker(root.fg, 1.5)
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }
}
