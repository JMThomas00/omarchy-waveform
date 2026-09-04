import QtQuick
import Quickshell
import Quickshell.Io

// Owns app-to-channel routing state and the live re-route
// (`pactl move-sink-input`). Like ChannelManager, this has no Pipewire
// import — BarWidget resolves stream nodes/ids and hands this component
// plain values (a pactl index, a match key, a target channel id).
//
// Persistence is enforced by BarWidget's own periodic reconciliation
// (checking every live stream's current sink against appAssignments and
// re-issuing the move if it drifted), NOT by a WirePlumber stream.rules
// config file. An earlier version of this component generated one and
// applied it via `systemctl --user restart wireplumber.service` — that
// mechanism is real (see git history / the plan's Risks section for the
// original design) but turned out to be actively harmful: confirmed
// directly that restarting wireplumber does NOT retroactively re-link an
// already-connected stream against a newly-written stream.rules entry —
// the stream landed back on the *default* sink instead of staying put,
// which is exactly the "routes, then reverts a few seconds later" bug
// report this rewrite fixes. WirePlumber's own restart is also a blip
// across all audio on the system, not just the one channel being routed.
// Active reconciliation avoids all of that: it only ever calls the same
// `pactl move-sink-input` already proven to work, on a timer, and it
// naturally also re-catches a stream that disappeared and came back
// (e.g. a browser tab that drops its audio node while paused).
Item {
  id: root

  readonly property string home: Quickshell.env("HOME")
  readonly property string configDir: home + "/.config/waveform"
  readonly property string routingStatePath: configDir + "/routing.json"

  // { matchKey: channelId } — channelId is "master" (routed back to the
  // default sink) or a real channel id.
  property var appAssignments: ({})
  property bool loaded: false

  // Set by BarWidget: the default output sink name ("master"'s target) and
  // the current set of real channel ids, so a stale assignment pointing at
  // a since-deleted channel is pruned instead of being reconciled forever
  // against a sink that no longer exists.
  property string defaultSinkName: ""
  property var validChannelIds: []

  function sinkNameFor(channelId) {
    if (channelId === "master") return root.defaultSinkName
    return "waveform_" + channelId
  }

  // ---------------------------------------------------------------- persistence

  FileView {
    id: stateFile
    path: root.routingStatePath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root._applyLoadedState(text())
    onLoadFailed: root._applyLoadedState("")
  }

  function _applyLoadedState(raw) {
    if (root.loaded) return
    var parsed = {}
    try {
      parsed = raw ? JSON.parse(raw) : {}
    } catch (e) {
      parsed = {}
    }
    root.appAssignments = (parsed && parsed.appAssignments) || {}
    root.loaded = true
  }

  Timer {
    id: saveTimer
    interval: 200
    repeat: false
    onTriggered: stateFile.setText(JSON.stringify({ version: 1, appAssignments: root.appAssignments }, null, 2) + "\n")
  }

  function _scheduleSave() {
    if (root.loaded) saveTimer.restart()
  }

  Process {
    id: mkdirProc
    // Removes the retired WirePlumber rule fragment left by the old
    // mechanism this component used to use — it's no longer regenerated,
    // and a stale rule sitting there is a landmine if wireplumber ever
    // restarts for an unrelated reason (system update, reboot) and
    // force-routes an app at a channel id that may not even exist anymore.
    command: ["bash", "-c", "mkdir -p \"$1\" && rm -f \"$2\"", "--",
      root.configDir, home + "/.config/wireplumber/wireplumber.conf.d/90-waveform-routing.conf"]
    onExited: stateFile.reload()
  }

  Component.onCompleted: mkdirProc.running = true

  // ---------------------------------------------------------------- one-shot commands

  Component { id: procComponent; Process {} }

  function _run(cmd, onDone) {
    var proc = procComponent.createObject(root, { command: cmd })
    proc.exited.connect(function(exitCode, exitStatus) {
      if (onDone) onDone(exitCode)
      proc.destroy()
    })
    proc.running = true
  }

  // Drops assignments pointing at channels that no longer exist — called
  // opportunistically by BarWidget's reconciliation pass rather than on a
  // timer of its own.
  function pruneStaleAssignments() {
    var pruned = {}
    var changed = false
    for (var key in root.appAssignments) {
      var channelId = root.appAssignments[key]
      if (channelId !== "master" && root.validChannelIds.indexOf(channelId) === -1) {
        changed = true
        continue
      }
      pruned[key] = channelId
    }
    if (changed) {
      root.appAssignments = pruned
      root._scheduleSave()
    }
  }

  // ---------------------------------------------------------------- routing

  // pactlIndex: the pactl/pipewire-pulse sink-input index (NOT Quickshell's
  // PwNode.id — see AppsModel.pactlIndexForStream). matchKey: application.name,
  // or null if the stream doesn't carry one — routing still applies live, it
  // just won't be remembered for next time. channelId: "master" or a real
  // channel id.
  function routeStream(pactlIndex, matchKey, channelId) {
    var sinkName = root.sinkNameFor(channelId)
    if (!sinkName) return
    root._run(["pactl", "move-sink-input", String(pactlIndex), sinkName], function(exitCode) {
      if (exitCode !== 0) console.warn("waveform: move-sink-input failed for stream", pactlIndex, "exit", exitCode)
    })
    if (!matchKey) return
    var updated = Object.assign({}, root.appAssignments)
    if (channelId === "master") delete updated[matchKey]
    else updated[matchKey] = channelId
    root.appAssignments = updated
    root._scheduleSave()
  }

  // Called every reconciliation tick for every live stream that has a
  // matchKey. A no-op unless that matchKey has a stored assignment AND the
  // stream's current sink doesn't already match it — so this is cheap to
  // call constantly, and it's what makes routing "stick": nothing needs to
  // revert it, but if anything ever does (or the app's stream disappears
  // and comes back as a fresh node), this catches it again within one tick.
  function reconcileStream(pactlIndex, matchKey, currentSinkName) {
    if (!matchKey) return
    var channelId = root.appAssignments[matchKey]
    if (!channelId) return
    var targetSinkName = root.sinkNameFor(channelId)
    if (!targetSinkName || targetSinkName === currentSinkName) return
    root._run(["pactl", "move-sink-input", String(pactlIndex), targetSinkName], function(exitCode) {
      if (exitCode !== 0) console.warn("waveform: reconcile move-sink-input failed for", matchKey, "exit", exitCode)
    })
  }
}
