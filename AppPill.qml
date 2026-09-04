import QtQuick
import qs.Commons

// A draggable app stream. `slot` (this Item) is what the parent Flow lays
// out; the visible/draggable Rectangle lives inside it at a (0,0)-relative
// position, so releasing a drag can always reset it exactly back into
// place with `pillRect.x = pillRect.y = 0`.
//
// The real pill still drives Drag/DropArea hit-testing (unaffected by
// clipping), but AppsDropZone's Apps box scrolls internally (ScrollView,
// clip: true, so a channel with many apps doesn't overflow) — which would
// otherwise clip the dragged pill invisible the instant it left its own
// zone's box. While dragging, this hides the real pill and mirrors its
// position/label/color onto `dragGhostRef`, a single shared unclipped
// visual living at MixerView's root — see DragGhost.qml.
//
// Property named `dragGhostRef`, deliberately NOT `dragGhost` — every
// component in this chain (AppsDropZone, ChannelColumn, MasterColumn) used
// to declare `property var dragGhost` and wire it up as
// `SomeComponent { dragGhost: dragGhost }` from MixerView.qml, where the
// RHS was meant to reference MixerView's `id: dragGhost`. That's a real QML
// footgun: the RHS of an object-literal property binding resolves against
// the object being constructed *first*, so `dragGhost: dragGhost` could
// self-reference the very property being assigned (still null) instead of
// the outer id — intermittently, depending on evaluation order. Confirmed
// directly: logging showed the same pill's ghost reference flipping
// between null and the real object across separate drags with no code
// change in between. Renaming the threaded property sidesteps the
// ambiguity entirely.
Item {
  id: slot

  required property var node
  required property string label
  property color accentColor: Color.accent
  property var dragGhostRef: null

  width: pillRect.width
  height: pillRect.height

  readonly property bool dragging: dragArea.drag.active

  onDraggingChanged: {
    if (!slot.dragGhostRef) return
    if (slot.dragging) {
      slot.dragGhostRef.text = slot.label
      slot.dragGhostRef.accentColor = slot.accentColor
      slot.dragGhostRef.visible = true
      slot._syncGhost()
    } else {
      slot.dragGhostRef.visible = false
    }
  }

  function _syncGhost() {
    if (!slot.dragGhostRef || !slot.dragging) return
    var pos = pillRect.mapToItem(slot.dragGhostRef.parent, 0, 0)
    slot.dragGhostRef.x = pos.x
    slot.dragGhostRef.y = pos.y
  }

  Rectangle {
    id: pillRect
    width: label_.implicitWidth + Style.space(14)
    height: label_.implicitHeight + Style.space(8)
    radius: Style.cornerRadius
    color: Qt.rgba(slot.accentColor.r, slot.accentColor.g, slot.accentColor.b, slot.dragging ? 0.4 : 0.18)
    border.width: Style.spacing.hairline
    border.color: slot.accentColor
    // Hidden (not just low-opacity) once the ghost takes over, so a
    // channel whose Apps box happens to still contain the drag's start
    // point doesn't show two overlapping copies.
    opacity: (slot.dragging && slot.dragGhostRef) ? 0 : 1
    z: slot.dragging ? 1000 : 0

    onXChanged: slot._syncGhost()
    onYChanged: slot._syncGhost()

    Drag.active: dragArea.drag.active
    Drag.source: slot
    Drag.hotSpot.x: width / 2
    Drag.hotSpot.y: height / 2

    Text {
      id: label_
      anchors.centerIn: parent
      text: slot.label
      color: Color.foreground
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }

    MouseArea {
      id: dragArea
      anchors.fill: parent
      drag.target: pillRect
      hoverEnabled: true
      cursorShape: Qt.OpenHandCursor
      // Belt-and-suspenders alongside pillRect's onXChanged/onYChanged:
      // this fires directly off the mouse event driving the drag, so the
      // ghost sync doesn't depend on drag.target's internal x/y writes
      // reliably raising change signals on every single move.
      onPositionChanged: if (dragArea.drag.active) slot._syncGhost()
      onReleased: {
        pillRect.Drag.drop()
        // Snap back into the Flow-managed slot position. If the drop was
        // accepted, this pill is about to be destroyed anyway (its stream
        // moves out of this zone's model); if it wasn't, this is what
        // actually returns it to where it belongs.
        pillRect.x = 0
        pillRect.y = 0
      }
    }
  }
}
