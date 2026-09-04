import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "EqBands.js" as EqBands
import "CavaConfigGen.js" as CavaConfigGen

// Per-channel EQ view (image #1's target layout): preset picker (prebuilt
// list for now — custom-saved presets and a favorites bar are a later
// polish pass) + the interactive band curve.
Item {
  id: root

  property QtObject bar: null
  property var channel: null
  // Merged, user-customized preset list (defaults minus any the user has
  // deleted, plus their own saved ones) — owned by ChannelManager, passed
  // straight through by BarWidget. Never `EqPresets.PRESETS` directly here,
  // so deletes/saves show up without needing the raw built-in list.
  property var presets: []
  // false only after BarWidget's confirmed `which cava` check comes back
  // missing — purely cosmetic (the spectrum fill behind the curve), so
  // this only skips the spawn attempt and shows a small hint, never blocks
  // EQ editing itself.
  property bool cavaAvailable: true

  signal backRequested()
  // Raw drag: bands changed by hand, detaches from whatever preset was
  // active (presetId goes null) — the caller (BarWidget) passes that
  // through to ChannelManager.setChannelEq as-is.
  signal bandsChanged(string channelId, var bands)
  signal presetSelected(string channelId, string presetId, var bands)
  signal presetSaveRequested(string channelId, string name, var bands)
  signal presetDeleteRequested(string presetId)

  readonly property color fg: bar ? bar.foreground : Color.foreground
  // This channel's own theme-hashed color (see BarWidget.channelColorFor)
  // so the curve/handles/active-preset highlight visually match its
  // header/fader/apps-zone color everywhere else — falls back to the
  // shared accent if unset.
  readonly property color channelAccent: (root.channel && root.channel.color) ? root.channel.color : Color.accent
  // Always normalized to the current EqBands.BANDS.length, never the raw
  // stored array as-is — a channel created before a band-count change
  // (e.g. the 6→12 band upgrade) can still hold a shorter array in
  // state.json until it's next saved, and reading that directly here would
  // let curve drags mutate a ragged/short array (`next[11] = db` on a
  // 6-length array leaves indices 6-10 as real `undefined` holes, not 0).
  readonly property var currentBands: EqBands.normalizeBands(channel && channel.eq ? channel.eq.bands : null)
  readonly property string currentPresetId: (channel && channel.eq) ? (channel.eq.presetId || "") : ""

  // ---------------------------------------------------------------- live spectrum
  //
  // Background fill behind the EQ curve, driven by a per-channel `cava`
  // process reading the channel's own monitor source (see
  // CavaConfigGen.js). Started once on open and stopped on close — this
  // whole Item only exists while its channel's EQ view is the active Loader
  // content (see BarWidget.qml's eqViewComponent), so onCompleted/
  // onDestruction line up exactly with entering/leaving this view.
  readonly property int spectrumBarCount: 48
  readonly property string cavaConfigDir: Quickshell.env("HOME") + "/.config/waveform/cava"
  readonly property string cavaConfigPath: root.channel ? (root.cavaConfigDir + "/" + root.channel.id + ".conf") : ""
  property var spectrumLevels: []
  property bool _cavaStopping: false

  function _onSpectrumLine(line) {
    var parts = String(line).split(";").filter(function(p) { return p.length > 0 })
    if (parts.length !== root.spectrumBarCount) return
    var levels = parts.map(function(p) {
      var n = Number(p)
      return isFinite(n) ? Math.max(0, Math.min(1, n / 100)) : 0
    })
    root.spectrumLevels = levels
  }

  function _startSpectrum() {
    if (!root.channel || !root.cavaAvailable) return
    mkdirProc.command = ["mkdir", "-p", root.cavaConfigDir]
    mkdirProc.running = true
  }

  function _writeConfigAndStartCava() {
    if (!root.channel) return
    cavaConfigWriter.path = root.cavaConfigPath
    cavaConfigWriter.setText(CavaConfigGen.renderConfig(root.channel.id, root.spectrumBarCount))
    cavaProc.command = ["cava", "-p", root.cavaConfigPath]
    cavaProc.running = true
  }

  function _stopSpectrum() {
    root._cavaStopping = true
    cavaProc.running = false
  }

  FileView { id: cavaConfigWriter; watchChanges: false; atomicWrites: true; printErrors: false }

  Process {
    id: mkdirProc
    onExited: root._writeConfigAndStartCava()
  }

  Process {
    id: cavaProc
    stdout: SplitParser {
      onRead: function(line) { root._onSpectrumLine(line) }
    }
    onExited: function(exitCode, exitStatus) {
      if (!root._cavaStopping && exitCode !== 0 && exitCode !== undefined)
        console.warn("waveform: cava exited unexpectedly for", root.channel ? root.channel.id : "?", "exit", exitCode)
    }
  }

  Component.onCompleted: root._startSpectrum()
  Component.onDestruction: root._stopSpectrum()

  function _onCurveDragged(index, db) {
    if (!root.channel) return
    var next = root.currentBands.slice()
    next[index] = db
    root.bandsChanged(root.channel.id, next)
  }

  function _selectPreset(preset) {
    if (!root.channel) return
    root.presetSelected(root.channel.id, preset.id, preset.bands.slice())
  }

  function _commitSavePreset() {
    var name = String(saveNameInput.text || "").trim()
    saveChip.editing = false
    if (!name || !root.channel) return
    root.presetSaveRequested(root.channel.id, name, root.currentBands.slice())
  }

  // Panel width tracks the mixer view's real content width (see
  // BarWidget.qml's mixerContentWidth) rather than this view's own natural
  // size, so switching between mixer/EQ never itself resizes the panel —
  // only adding/removing a channel does. Falls back to the old constant if
  // ever instantiated without it.
  property real viewWidth: Style.space(520)

  implicitWidth: root.viewWidth
  implicitHeight: column.implicitHeight + Style.space(32)

  Column {
    id: column
    anchors.horizontalCenter: parent.horizontalCenter
    spacing: Style.space(14)
    width: Math.max(Style.space(360), root.viewWidth - Style.space(32))

    Row {
      spacing: Style.space(10)

      Text {
        text: "‹ Mixer"
        color: root.fg
        font.family: root.bar ? root.bar.fontFamily : undefined
        font.pixelSize: Style.font.body
        opacity: 0.8

        MouseArea {
          anchors.fill: parent
          anchors.margins: -Style.space(6)
          cursorShape: Qt.PointingHandCursor
          onClicked: root.backRequested()
        }
      }
    }

    Text {
      text: (root.channel ? root.channel.name : "Channel") + " — EQ"
      color: root.fg
      font.family: root.bar ? root.bar.fontFamily : undefined
      font.pixelSize: Style.font.heading
      font.bold: true
    }

    Text {
      text: "PRESET"
      color: Qt.darker(root.fg, 1.6)
      font.family: root.bar ? root.bar.fontFamily : undefined
      font.pixelSize: Style.font.caption
      font.letterSpacing: 1
    }

    Flow {
      width: parent.width
      spacing: Style.space(6)

      Repeater {
        model: root.presets

        Rectangle {
          id: chip
          required property var modelData
          readonly property bool active: root.currentPresetId === modelData.id
          width: chipRow.implicitWidth + Style.space(16)
          height: chipRow.implicitHeight + Style.space(10)
          radius: Style.cornerRadius
          color: active
            ? Style.selectedFillFor(root.fg, root.channelAccent)
            : (presetArea.containsMouse ? Style.hoverFillFor(root.fg, root.channelAccent) : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.05))
          border.width: Style.spacing.hairline
          border.color: active ? root.channelAccent : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.12)

          // Declared before chipRow so the delete glyph's own MouseArea
          // (on top, smaller hitbox) wins clicks over its own bounds while
          // this one still catches everything else in the chip.
          MouseArea {
            id: presetArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root._selectPreset(chip.modelData)
          }

          Row {
            id: chipRow
            anchors.centerIn: parent
            spacing: Style.space(6)

            Text {
              id: presetLabel
              anchors.verticalCenter: parent.verticalCenter
              text: chip.modelData.name
              color: chip.active ? root.channelAccent : root.fg
              font.family: root.bar ? root.bar.fontFamily : undefined
              font.pixelSize: Style.font.bodySmall
              font.bold: chip.active
            }

            Text {
              visible: presetArea.containsMouse
              anchors.verticalCenter: parent.verticalCenter
              text: "×"
              color: Qt.darker(root.fg, 1.6)
              font.family: root.bar ? root.bar.fontFamily : undefined
              font.pixelSize: Style.font.bodySmall

              MouseArea {
                anchors.fill: parent
                anchors.margins: -Style.space(4)
                cursorShape: Qt.PointingHandCursor
                onClicked: root.presetDeleteRequested(chip.modelData.id)
              }
            }
          }
        }
      }

      Rectangle {
        id: saveChip
        property bool editing: false
        width: (editing ? saveNameInput.width : saveLabel.implicitWidth) + Style.space(16)
        height: saveLabel.implicitHeight + Style.space(10)
        radius: Style.cornerRadius
        color: saveArea.containsMouse ? Style.hoverFillFor(root.fg, Color.accent) : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.05)
        border.width: Style.spacing.hairline
        border.color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.12)

        Text {
          id: saveLabel
          visible: !saveChip.editing
          anchors.centerIn: parent
          text: "+ Save as…"
          color: root.fg
          font.family: root.bar ? root.bar.fontFamily : undefined
          font.pixelSize: Style.font.bodySmall
        }

        TextInput {
          id: saveNameInput
          visible: saveChip.editing
          anchors.verticalCenter: parent.verticalCenter
          anchors.left: parent.left
          anchors.leftMargin: Style.space(8)
          width: Math.max(Style.space(70), implicitWidth + Style.space(4))
          color: root.fg
          font.family: root.bar ? root.bar.fontFamily : undefined
          font.pixelSize: Style.font.bodySmall
          onVisibleChanged: if (visible) { text = ""; forceActiveFocus() }
          onAccepted: root._commitSavePreset()
          onEditingFinished: root._commitSavePreset()
          Keys.onEscapePressed: {
            saveNameInput.text = ""
            saveChip.editing = false
          }
        }

        MouseArea {
          id: saveArea
          anchors.fill: parent
          hoverEnabled: true
          enabled: !saveChip.editing
          cursorShape: Qt.PointingHandCursor
          onClicked: saveChip.editing = true
        }
      }
    }

    Text {
      text: root.currentPresetId ? "" : "Custom — drag any point below to shape the curve"
      visible: !root.currentPresetId
      color: Qt.darker(root.fg, 1.5)
      font.family: root.bar ? root.bar.fontFamily : undefined
      font.pixelSize: Style.font.caption
      font.italic: true
    }

    Text {
      visible: !root.cavaAvailable
      text: "No live spectrum — cava isn't installed. Install with: sudo pacman -S cava"
      color: Qt.darker(root.fg, 1.5)
      font.family: root.bar ? root.bar.fontFamily : undefined
      font.pixelSize: Style.font.caption
      font.italic: true
    }

    EqCurve {
      width: parent.width
      height: Style.space(260)
      bar: root.bar
      bands: root.currentBands
      accentColor: root.channelAccent
      spectrumLevels: root.spectrumLevels
      spectrumColor: Color.accent
      onBandDragged: function(index, db) { root._onCurveDragged(index, db) }
    }
  }
}
