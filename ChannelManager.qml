import QtQuick
import Quickshell
import Quickshell.Io
import "ChannelStore.js" as Store
import "FilterChainGen.js" as FilterChainGen
import "SystemdUnitGen.js" as SystemdUnitGen
import "EqBands.js" as EqBands
import "EqPresets.js" as EqPresets

// Owns Waveform's channel list: persistence (state.json) and the real
// per-channel create/delete lifecycle — a hosted PipeWire filter-chain
// client + systemd --user unit per channel, per the plan's M2 milestone and
// its Architecture section. Deliberately has no Pipewire-service import:
// resolving each channel's live PwNode stays in BarWidget.qml, which already
// owns that; this component only knows about state.json and the files/units
// it renders on disk.
Item {
  id: root

  readonly property string home: Quickshell.env("HOME")
  // Deliberately NOT under ~/.config/omarchy/plugins/waveform/ (the plugin's
  // own source directory): Quickshell watches that tree for hot-reload, so
  // every save here would fire "local plugin changed" mid-operation — which
  // was tearing down and rebuilding this whole component while a multi-step
  // systemctl command queue (see _pump below) was still in flight, silently
  // dropping whatever hadn't run yet. Confirmed directly: deleteChannel()'s
  // final `rm -f` step never fired, only because state.json's own write
  // (~200ms after the delete started) landed on the plugin dir and reloaded
  // it out from under the in-flight queue.
  readonly property string configDir: home + "/.config/waveform"
  readonly property string statePath: configDir + "/state.json"
  readonly property string pipewireConfDir: home + "/.config/pipewire"
  readonly property string systemdUserDir: home + "/.config/systemd/user"

  property var channels: []
  property bool loaded: false

  // EQ presets are global (shared across all channels), not per-channel —
  // see the plan's Data model table. Same state.json document as channels,
  // just a different top-level key (Store.parseDocument/serializeDocument
  // handle both together).
  property var customPresets: []
  property var deletedDefaultPresetIds: []
  readonly property var visiblePresets: EqPresets.mergePresets(root.customPresets, root.deletedDefaultPresetIds)

  // ChannelMix's side membership persists (so it's still set up next time
  // the panel opens) — either side can hold several channels grouped
  // together. The fade position itself does not — see BarWidget.qml, which
  // owns that transient runtime state.
  property var channelMixSideA: []
  property var channelMixSideB: []

  function setChannelMixGroups(sideA, sideB) {
    root.channelMixSideA = sideA || []
    root.channelMixSideB = sideB || []
    root._scheduleSave()
  }

  // Set by BarWidget from Pipewire.defaultAudioSink/defaultAudioSource —
  // the device a newly created output/input channel targets by default.
  property string defaultSinkName: ""
  property string defaultSourceName: ""

  function channelConfPath(id) { return root.pipewireConfDir + "/" + SystemdUnitGen.confName(id) }
  function channelUnitPath(id) { return root.systemdUserDir + "/" + SystemdUnitGen.unitName(id) }

  // ---------------------------------------------------------------- persistence

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root._applyLoadedState(text())
    onLoadFailed: root._applyLoadedState("")
  }

  function _applyLoadedState(raw) {
    if (root.loaded) return
    var doc = Store.parseDocument(raw)
    root.channels = doc.channels
    root.customPresets = doc.customPresets
    root.deletedDefaultPresetIds = doc.deletedDefaultPresetIds
    root.channelMixSideA = doc.channelMixSideA
    root.channelMixSideB = doc.channelMixSideB
    root.loaded = true
  }

  Timer {
    id: saveTimer
    interval: 200
    repeat: false
    onTriggered: stateFile.setText(Store.serializeDocument(root.channels, root.customPresets, root.deletedDefaultPresetIds, root.channelMixSideA, root.channelMixSideB))
  }

  function _scheduleSave() {
    if (!root.loaded) return
    saveTimer.restart()
  }

  Process {
    id: mkdirProc
    command: ["mkdir", "-p", root.configDir, root.pipewireConfDir, root.systemdUserDir]
    onExited: stateFile.reload()
  }

  Component.onCompleted: mkdirProc.running = true

  // ---------------------------------------------------------------- channel file writers

  FileView { id: confWriter; watchChanges: false; atomicWrites: true; printErrors: false }
  FileView { id: unitWriter; watchChanges: false; atomicWrites: true; printErrors: false }

  function _writeChannelFiles(channel) {
    confWriter.path = root.channelConfPath(channel.id)
    confWriter.setText(FilterChainGen.renderChannelConf(channel))
    unitWriter.path = root.channelUnitPath(channel.id)
    unitWriter.setText(SystemdUnitGen.renderUnit(channel))
  }

  // ---------------------------------------------------------------- sequential command runner
  //
  // Each queued command gets its own dynamically-created Process (destroyed
  // once it exits) rather than reusing one Process instance across different
  // commands — same dynamic-creation pattern Linecast's liveProcComponent
  // uses, just one-shot instead of long-running.

  property var _queue: []
  property bool _opRunning: false

  Component { id: procComponent; Process {} }

  function _enqueue(cmd, onDone) {
    root._queue.push({ cmd: cmd, onDone: onDone || null })
    root._pump()
  }

  function _pump() {
    if (root._opRunning || root._queue.length === 0) return
    root._opRunning = true
    var next = root._queue.shift()
    var proc = procComponent.createObject(root, { command: next.cmd })
    proc.exited.connect(function(exitCode, exitStatus) {
      root._opRunning = false
      if (next.onDone) next.onDone(exitCode)
      proc.destroy()
      root._pump()
    })
    proc.running = true
  }

  // ---------------------------------------------------------------- create / delete

  function createChannel(name, type) {
    if (!root.loaded) return
    var isInput = type === "input"
    var defaultDevice = isInput ? root.defaultSourceName : root.defaultSinkName
    if (!defaultDevice) {
      console.warn("waveform: no default", isInput ? "input source" : "output sink", "resolved yet, cannot create channel")
      return
    }
    var channel = Store.makeChannel(name, defaultDevice, type)
    root.channels = root.channels.concat([channel])
    root._scheduleSave()
    root._writeChannelFiles(channel)
    root._enqueue(["systemctl", "--user", "daemon-reload"], function() {
      root._enqueue(["systemctl", "--user", "enable", "--now", SystemdUnitGen.unitName(channel.id)], function(exitCode) {
        if (exitCode !== 0)
          console.warn("waveform: failed to start channel unit for", channel.id, "exit", exitCode)
      })
    })
  }

  // Called by BarWidget once it observes the channel's PwNode actually
  // appear in Pipewire.nodes (it owns that reactive list, this component
  // doesn't). BarWidget also rolls a channel back via deleteChannel() below
  // if the node never appears within its timeout — the poll-verify-rollback
  // half of the lifecycle this milestone's Risks section calls for.
  function markChannelActive(id) {
    var found = false
    root.channels = root.channels.map(function(c) {
      if (c.id !== id) return c
      found = true
      return Object.assign({}, c, { status: "active" })
    })
    if (found) root._scheduleSave()
  }

  // Renames are baked into the channel's own hosted config (node.description
  // / media.name), which PipeWire only reads at that client's startup — so
  // this restarts just that one channel's unit to pick up the new name.
  // node.name itself (the "waveform_<id>" sink name apps route by) never
  // changes, so this doesn't disturb any WirePlumber routing rule.
  function renameChannel(id, newName) {
    var trimmed = String(newName || "").trim()
    if (!trimmed) return
    var target = null
    root.channels = root.channels.map(function(c) {
      if (c.id !== id) return c
      target = Object.assign({}, c, { name: trimmed })
      return target
    })
    if (!target) return
    root._scheduleSave()
    root._regenerateAndRestart(target, "rename")
  }

  // Changing which real device a channel targets is a topology change
  // (`target.object` in the hosted client's own config), same class of
  // change as a rename — needs the regenerated .conf actually loaded, which
  // only happens on restart, not a live pw-cli param like an EQ gain does.
  function setChannelDevice(id, deviceName) {
    var trimmed = String(deviceName || "").trim()
    if (!trimmed) return
    var target = null
    root.channels = root.channels.map(function(c) {
      if (c.id !== id) return c
      target = Object.assign({}, c, { device: trimmed })
      return target
    })
    if (!target) return
    root._scheduleSave()
    root._regenerateAndRestart(target, "device change")
  }

  // Shared regen-.conf + daemon-reload + restart tail for any change that
  // needs the hosted client to actually reload its config to take effect
  // (rename, device change) — daemon-reload first so systemd's own cached
  // unit metadata (the Description= line, when it changed) doesn't stay
  // stale even though the process itself re-execs against the new .conf
  // fine either way (confirmed directly, during the original rename work).
  function _regenerateAndRestart(target, reasonForLog) {
    root._writeChannelFiles(target)
    root._enqueue(["systemctl", "--user", "daemon-reload"], function() {
      root._enqueue(["systemctl", "--user", "restart", SystemdUnitGen.unitName(target.id)], function(exitCode) {
        if (exitCode !== 0) console.warn("waveform: failed to restart channel unit after", reasonForLog, target.id, "exit", exitCode)
      })
    })
  }

  // Called continuously while the user drags a curve point (live UI
  // feedback) as well as once on release/preset-select. `presetId` is
  // optional (pass undefined to leave whatever the channel already had —
  // dragging a curve point by hand implicitly detaches from any prebuilt
  // preset, handled by the caller passing null explicitly in that case).
  //
  // This does NOT restart the channel's unit. An earlier version did (same
  // regen-then-restart pattern as renameChannel above), and it was a real
  // problem, not just a brief blip: restarting recreates the channel's
  // virtual sink with a fresh PipeWire object id, and at least some real
  // apps (confirmed directly: a CLI player and a browser tab both) treat
  // their output sink vanishing out from under them as a playback error and
  // pause rather than silently following the reconnect. Every EQ tweak was
  // pausing whatever was routed to that channel.
  //
  // The fix: PipeWire's filter-chain module exposes every LV2 control port
  // as a live-settable Props param on the channel's own node (confirmed
  // directly via `pw-cli enum-params <id> Props`, which lists e.g. "eq:g_4"
  // right alongside the node's ordinary volume/mute props) — BarWidget.qml
  // applies gain changes live via `pw-cli set-param`, using the channel's
  // already-resolved PwNode id, with zero process restart and therefore no
  // sink disappearance at all. This function's job shrinks to what's left:
  // update in-memory state and (debounced) persist the regenerated .conf so
  // a *future* restart — a rename, a crash, a reboot — starts back up with
  // the last-applied curve already baked in, without needing to restart
  // anything just to get there.
  Timer {
    id: eqPersistTimer
    interval: 250
    repeat: false
    property string pendingChannelId: ""
    onTriggered: root._persistChannelEq(pendingChannelId)
  }

  function setChannelEq(id, bands, presetId) {
    var target = null
    root.channels = root.channels.map(function(c) {
      if (c.id !== id) return c
      var nextPresetId = presetId === undefined ? (c.eq ? c.eq.presetId : null) : presetId
      target = Object.assign({}, c, { eq: { presetId: nextPresetId, bands: bands } })
      return target
    })
    if (!target) return
    root._scheduleSave()
    eqPersistTimer.pendingChannelId = id
    eqPersistTimer.restart()
  }

  function _persistChannelEq(id) {
    var target = null
    for (var i = 0; i < root.channels.length; i++) if (root.channels[i].id === id) target = root.channels[i]
    if (!target) return
    root._writeChannelFiles(target)
  }

  // ---------------------------------------------------------------- EQ presets

  // Saves the currently-dragged curve as a new named preset (distinct from
  // the 6 built-ins, `custom_...`-prefixed id — see ChannelStore.generatePresetId).
  // Returns the new preset's id (so the caller can immediately select it as
  // the channel's active preset), or null if the name was blank.
  function savePreset(name, bands) {
    var trimmed = String(name || "").trim()
    if (!trimmed) return null
    var preset = { id: Store.generatePresetId(), name: trimmed, bands: EqBands.normalizeBands(bands) }
    root.customPresets = root.customPresets.concat([preset])
    root._scheduleSave()
    return preset.id
  }

  // Deletes a custom preset outright, or — for one of the 6 built-ins —
  // records it as deleted so it stays hidden from the picker across
  // reloads. Either way this doesn't touch any channel currently using that
  // preset: its bands are already baked into that channel's own `eq.bands`,
  // it just stops resolving to a preset name afterward (falls back to
  // "Custom" — see EqPresets.presetNameForIn).
  function deletePreset(id) {
    if (!id) return
    var wasCustom = false
    root.customPresets = root.customPresets.filter(function(p) {
      if (p.id === id) { wasCustom = true; return false }
      return true
    })
    if (!wasCustom && root.deletedDefaultPresetIds.indexOf(id) === -1) {
      root.deletedDefaultPresetIds = root.deletedDefaultPresetIds.concat([id])
    }
    root._scheduleSave()
  }

  // Reorders channels by moving `draggedId` to occupy `targetId`'s current
  // position — pure display/list order, not a topology change: nothing
  // about a channel's own hosted filter-chain client or systemd unit cares
  // what index it renders at, so this only touches the in-memory array and
  // persists it (no .conf regen, no restart, unlike rename/setChannelDevice
  // above).
  //
  // Direction matters, which side of the target `dragged` lands on:
  // dragging *forward* (dragged started before target) inserts AFTER the
  // target, pulling target one slot left; dragging *backward* (dragged
  // started after target) inserts BEFORE it, pushing target one slot
  // right. An earlier version always inserted before the target regardless
  // of direction — real bug, caught by the user: dragging a channel onto
  // its own immediate right neighbor removed it and reinserted it into the
  // exact slot it had just vacated (a true no-op, not just a visual one),
  // since "the slot right before the target" and "the dragged item's
  // starting slot" are the same position when they were already adjacent.
  // Directional insertion fixes that case and also generalizes to a real
  // swap for any pair of positions, forward or backward.
  function reorderChannel(draggedId, targetId) {
    if (!draggedId || !targetId || draggedId === targetId) return
    var dragIndex = -1, targetIndex = -1
    for (var i = 0; i < root.channels.length; i++) {
      if (root.channels[i].id === draggedId) dragIndex = i
      if (root.channels[i].id === targetId) targetIndex = i
    }
    if (dragIndex === -1 || targetIndex === -1) return
    var movingForward = dragIndex < targetIndex
    var dragged = root.channels[dragIndex]
    var rest = root.channels.filter(function(c) { return c.id !== draggedId })
    var newTargetIndex = -1
    for (var j = 0; j < rest.length; j++) {
      if (rest[j].id === targetId) { newTargetIndex = j; break }
    }
    if (newTargetIndex === -1) return
    rest.splice(movingForward ? newTargetIndex + 1 : newTargetIndex, 0, dragged)
    root.channels = rest
    root._scheduleSave()
  }

  function deleteChannel(id) {
    var existed = false
    for (var i = 0; i < root.channels.length; i++) if (root.channels[i].id === id) existed = true
    if (!existed) return
    root.channels = root.channels.filter(function(c) { return c.id !== id })
    root._scheduleSave()
    var confPath = root.channelConfPath(id)
    var unitPath = root.channelUnitPath(id)
    root._enqueue(["systemctl", "--user", "disable", "--now", SystemdUnitGen.unitName(id)], function() {
      root._enqueue(["systemctl", "--user", "daemon-reload"], function() {
        root._enqueue(["rm", "-f", confPath, unitPath], function() {})
      })
    })
  }
}
