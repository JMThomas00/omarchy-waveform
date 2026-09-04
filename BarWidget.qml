import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire
import qs.Ui
import qs.Commons
import "AppsModel.js" as AppsModel
import "EqBands.js" as EqBands
import "ThemePaletteGen.js" as ThemePaletteGen

// Waveform — SteelSeries Sonar-inspired per-app audio mixer.
//
// M2: real channel CRUD — each channel in channelManager.channels is backed
// by its own hosted PipeWire filter-chain client + systemd --user unit (see
// ChannelManager.qml), created via "+" and removed via a channel's delete
// affordance. M3 adds real app routing: RoutingManager owns the live
// pactl move-sink-input + the persisted WirePlumber rule; this component
// resolves the live stream/link graph (RoutingManager, like ChannelManager,
// has no Pipewire-service dependency of its own) and reconciles "pending"
// channels into "active" once their sink appears, or rolls them back if it
// never does.
BarWidget {
  id: root
  moduleName: "jmthomas00.waveform"

  // "mixer" | "eq" — see Linecast's BarWidget.qml for the precedent this
  // single-popup, internal-view-switch pattern is based on.
  property string activeView: "mixer"
  property string activeChannelId: ""

  // Panel width tracks the mixer view's real content width (row of columns,
  // grows/shrinks with channel count) regardless of which view is showing —
  // see the mixerViewComponent's implicitWidth bindings below. Without this,
  // a fixed constant here doesn't grow when a channel is added, and mixer's
  // own Row overflows the panel's border. EqView adopts the same cached
  // width (its `viewWidth` prop) instead of sizing itself independently, so
  // switching to/from the EQ view never itself resizes the panel — only
  // adding/removing a channel does. Height is left per-view (each view's own
  // `implicitHeight`, unchanged) since channel count only ever affects
  // width in this Row-based mixer layout.
  property real mixerContentWidth: Style.space(560)

  readonly property var masterSink: Pipewire.defaultAudioSink
  readonly property var masterSource: Pipewire.defaultAudioSource
  readonly property var nodes: Pipewire.nodes ? Pipewire.nodes.values : []
  readonly property var linkGroups: Pipewire.linkGroups ? Pipewire.linkGroups.values : []

  // Real, selectable devices for the device dropdown. Excludes every one of
  // Waveform's own hosted nodes (own sinks/sources AND their hidden
  // _output/_capture sides) so a channel never lists itself or another
  // channel as a target device. Takes `ownSinkNames` explicitly (rather
  // than reading root.channelSinkNames itself) so it stays a pure function
  // callable mid-recompute in _recomputePipewireDerived below, before
  // root.channelSinkNames has been updated to match.
  function _isOwnHostedNode(name, ownSinkNames) {
    for (var i = 0; i < ownSinkNames.length; i++) {
      var base = ownSinkNames[i]
      if (name === base || name === base + "_output" || name === base + "_capture") return true
    }
    return false
  }

  // `n.type` is a PwNodeType flags value (an int), not a string — comparing
  // `String(n.type)` against "AudioSource" was always false (it just
  // stringifies to the raw bitmask number, confirmed directly: the filter
  // silently matched zero real input devices even with one genuinely
  // present). Fixed with a bitwise-AND — but `!== 0` (any overlapping bit)
  // was ALSO wrong, confirmed directly: it let in the real *output* device
  // and an unrelated v4l2 webcam. `PwNodeType`'s 13 named flags can't each
  // be a unique bit in a quint8 (max 8 bits) — composite flags like
  // `AudioSource` are almost certainly `Audio | Source` as a combined mask,
  // not their own dedicated bit, so a webcam (`Video | Source`) or a plain
  // output sink (`Audio | Sink`) each still shares *one* bit with
  // `AudioSource` and passed a `!== 0` check. Requiring the full mask to
  // match (`=== PwNodeType.AudioSource`) fixed both false positives.
  // Populated only by _recomputePipewireDerived below — see that function's
  // own comment for why these moved off live reactive bindings.
  property var realOutputDevices: []
  property var realInputDevices: []

  // ---------------------------------------------------------------- theming
  //
  // Per-channel color: hashed off each channel's immutable id (see
  // ThemePaletteGen.stableHash/colorIndexForId) into the active theme's
  // real vivid palette — never creation order, so deleting one channel
  // never reshuffles the colors of the ones that are left. Read once here
  // (not per-component like EqCurve.qml's spectrum did during M4, before
  // this milestone existed) so every place that needs a channel color
  // shares one FileView/parse instead of each duplicating it.
  // NOT watchChanges: true, deliberately. `omarchy-theme-set` never
  // rewrites colors.toml in a way a file-watcher can react to usefully —
  // confirmed by reading the script directly: it reads the new
  // colors.toml/shell.toml itself, base64-encodes them, and pushes the
  // content straight into the *already-running* shell process via
  // `qs ipc call shell applyTheme <b64colors> <b64shell>` (or the
  // `background themeTransition` variant, same destination), which calls
  // `Color.loadColors()`/`loadShell()` directly, in-process — colors.toml
  // is never re-read from disk by the running shell at all. That IPC
  // target is call/response only, with no broadcast/signal a third-party
  // plugin can subscribe to, so there's no event to hook here even in
  // principle. (Confirmed the file-watch path really doesn't work despite
  // that, the hard way: `watchChanges: true` here DID fire `onFileChanged`
  // on a live `omarchy theme set`, but the `reload()` it triggered never
  // actually picked up the new content — `text()` stayed stale, every
  // channel kept its previous theme's colors until a full `omarchy restart
  // shell`.) Re-reading whenever the panel opens instead covers the
  // realistic case — change the theme, then open Waveform later — without
  // depending on a signal this plugin has no way to receive.
  readonly property string _themeColorsPath: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"
  property var _themePaletteHex: []
  readonly property var themePalette: root._themePaletteHex.map(function(h) { return Qt.color(h) })

  FileView {
    id: themeColorsFile
    path: root._themeColorsPath
    watchChanges: false
    printErrors: false
    onLoaded: root._themePaletteHex = ThemePaletteGen.parseSortedPalette(text())
  }

  onOpenedChanged: if (root.opened) { themeColorsFile.reload(); root._refreshDisplaySnapshots(); root._checkDependencies() }

  // Covers the case the open-transition refresh above doesn't: the panel
  // was already open when the theme changed underneath it (confirmed
  // directly — the built-in shell's own accent/foreground DID update live
  // in that case, since the shell pushes those via IPC straight into
  // Color.qml's already-live singleton, but this plugin's own separately-
  // read palette stayed on the old theme until the panel was closed and
  // reopened). A few-second poll while open is cheap (colors.toml is
  // ~1KB) and turns "stayed wrong until you closed the panel" into "catches
  // up within a few seconds," matching how close a plugin can realistically
  // get without a live-update event to hook (see gotcha #14 / the comment
  // above _themeColorsPath — there isn't one).
  Timer {
    interval: 3000
    repeat: true
    running: root.opened
    onTriggered: themeColorsFile.reload()
  }

  // Falls back to the one theme color already wired everywhere else
  // (Color.accent) if the theme file is missing/unreadable/too sparse —
  // same fallback EqCurve.qml's spectrum uses for the same reason.
  function channelColorFor(channelId) {
    if (root.themePalette.length === 0) return Color.accent
    return root.themePalette[ThemePaletteGen.colorIndexForId(channelId, root.themePalette.length)]
  }

  // ------------------------------------------------------ external deps
  //
  // Waveform needs two things installed that it can't bundle itself (see
  // the plan doc's marketplace-submission section for why): `lsp-plugins-lv2`
  // (the LV2 EQ every channel's filter-chain hosts — without it, a new
  // channel's sink fails to come up at all, silently rolling back after
  // `channelStartupTimeoutMs` with nothing but a console.warn no one but a
  // developer would ever see) and `cava` (purely cosmetic — the live
  // spectrum behind the EQ curve, everything else works fine without it).
  // Checked once at startup and again each time the panel opens (cheap:
  // one `test`/`which` spawn each), so installing either mid-session and
  // reopening the panel clears the warning without a full shell restart.
  //
  // The marker path is the exact file the documented `pacman -S
  // lsp-plugins-lv2` install produces (confirmed directly on this system:
  // `pacman -Ql lsp-plugins-lv2` lists it under the package's single combined
  // `lsp-plugins.lv2` bundle, not its own per-plugin directory) — this only
  // recognizes that standard install location, not a custom LV2_PATH.
  readonly property string _lspEqMarkerPath: "/usr/lib/lv2/lsp-plugins.lv2/para_equalizer_x16_stereo.ttl"
  property bool lspEqAvailable: true
  property bool cavaAvailable: true

  function _checkDependencies() {
    if (!lspEqCheckProc.running) { lspEqCheckProc.command = ["test", "-f", root._lspEqMarkerPath]; lspEqCheckProc.running = true }
    if (!cavaCheckProc.running) { cavaCheckProc.command = ["which", "cava"]; cavaCheckProc.running = true }
  }

  Process {
    id: lspEqCheckProc
    running: false
    command: []
    onExited: function(exitCode) { root.lspEqAvailable = exitCode === 0 }
  }

  Process {
    id: cavaCheckProc
    running: false
    command: []
    onExited: function(exitCode) { root.cavaAvailable = exitCode === 0 }
  }

  function findSinkByName(name) {
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (n && n.isSink && !n.isStream && String(n.name) === name) return n
    }
    return null
  }

  // Matches by name only, no isSink/isStream filtering — needed for a
  // channel's "_output" node, which reports both isSink AND isStream true
  // (see AppsModel.isChannelOwnOutputStream) and so is excluded by
  // findSinkByName's stricter filter.
  function findNodeByName(name) {
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (n && String(n.name) === name) return n
    }
    return null
  }

  // Real channel list with each one's live node(s) resolved, but without
  // `apps` yet — streamAssignments (below) needs this first to know which
  // sink names count as "a channel", and channels (further below) layers
  // `apps` back on top. Splitting it this way avoids a circular binding.
  //
  // For an OUTPUT channel, `outputNode` (the "_output" node, right before
  // its audio reaches the physical device) is what the live level meter
  // should watch — NOT `node` (the capture-side sink whose .audio.volume
  // the fader controls). Confirmed directly: watching the capture side,
  // the meter reflected the *incoming* app audio level, uncapped by this
  // channel's own volume — a channel set to 81% showed peaks near 100%
  // whenever the routed app's raw output was louder than that.
  //
  // An INPUT channel has no equivalent split: its only user-facing node
  // IS "waveform_<id>" itself (the virtual mic apps pick, media.class
  // Audio/Source — see FilterChainGen.renderInputRouting), already the
  // post-EQ, post-fader-gain result. The hidden capture-from-real-mic side
  // ("waveform_<id>_capture") isn't user-adjustable at all, so there's no
  // "meter watches the wrong side" risk to guard against — `node` and
  // `outputNode` are deliberately the same PwNode for an input channel.
  // `eqControlNode` is separate from both `node` and `outputNode`: the
  // filter-chain module always exposes its LV2 plugin's controls
  // ("eq:g_N" etc, see applyEqLive below) as Props on whichever side plays
  // the *capture* role inside the module itself, regardless of which side
  // ends up "user-facing" via media.class. For an output channel that's
  // the same node the fader controls (`node`) — confirmed back in M4. For
  // an input channel it's the *hidden* "_capture" node, NOT the exposed
  // "waveform_<id>" virtual mic (`node`/`outputNode` here) — confirmed
  // directly, the hard way: `pw-cli enum-params` on the exposed mic node
  // came back with zero "eq:*" keys, only plain adapter Props
  // (volume/mute/channelmix.*); the same call against its "_capture"
  // sibling listed all 16 gain ports. Without this, live EQ dragging on a
  // mic channel would silently target the wrong node and do nothing.
  // Populated only by _recomputePipewireDerived below.
  property var baseChannels: []
  property var channelSinkNames: []
  property var playbackStreams: []
  // { "master": [stream,...], "<channelId>": [stream,...] } — grouped by
  // each stream's *live* sink connection (the WirePlumber link graph is the
  // source of truth here, not stored assignment intent), so a channel
  // column always shows what's actually playing through it right now.
  property var streamAssignments: ({ master: [] })
  property var masterApps: []
  property var channels: []

  function currentSinkForStream(streamNode) {
    for (var i = 0; i < root.linkGroups.length; i++) {
      var g = root.linkGroups[i]
      if (g && g.source && streamNode && g.source.id === streamNode.id) return g.target
    }
    return null
  }

  // Recomputes the whole PipeWire-derived cascade above (device lists,
  // channel/node resolution, app-to-channel routing) in one pass, called
  // from the timer below and immediately on any channelManager.channels
  // change — NOT bound as live reactive properties off root.nodes the way
  // this used to be written. `root.nodes`/`root.linkGroups` change
  // reference on essentially any PipeWire node property tick (peak level,
  // anything at all — see gotcha #8), so as plain `readonly property var`
  // bindings this whole cascade (several O(nodes*channels) filters/maps,
  // one of them nested) was re-executing in full on every single one of
  // those ticks while the panel was open — exactly when smoothness matters
  // most. The Repeater-facing displayChannels/displayMasterApps snapshot
  // below only ever throttled who *consumed* this cascade, never the
  // recomputation itself. Also fixes a second, related cost: every
  // ChannelColumn's DeviceDropdown Repeater was bound straight to
  // realOutputDevices/realInputDevices (MixerView.qml's
  // `availableDevices:`), so this cascade re-executing on every tick also
  // meant every column's device-list Repeater rebuilding on every tick,
  // even for the (usually all) collapsed/closed dropdowns. Throttling the
  // source to the same ~150ms cadence _refreshDisplaySnapshots already
  // uses cuts both to ~7/sec regardless of PipeWire tick rate — a
  // real-time channel/device list only ever needed to feel "live," not to
  // update at meter-refresh frequency, and every consumer below already
  // tolerates up to one tick (150ms) of staleness or gets an immediate
  // refresh on the topology changes (rename/create/delete/status) that
  // actually need to be prompt.
  function _recomputePipewireDerived() {
    var nodes = root.nodes

    var baseChannels = channelManager.channels.map(function(c) {
      var isInput = c.type === "input"
      var userNode = isInput ? root.findNodeByName("waveform_" + c.id) : root.findSinkByName("waveform_" + c.id)
      return {
        id: c.id, name: c.name, type: c.type, status: c.status, eq: c.eq,
        device: c.device,
        node: userNode,
        outputNode: isInput ? userNode : root.findNodeByName("waveform_" + c.id + "_output"),
        eqControlNode: isInput ? root.findNodeByName("waveform_" + c.id + "_capture") : userNode
      }
    })
    var channelSinkNames = baseChannels.map(function(c) { return "waveform_" + c.id })

    var realOutputDevices = nodes.filter(function(n) {
      return n && n.isSink && !n.isStream && !root._isOwnHostedNode(String(n.name), channelSinkNames)
    })
    var realInputDevices = nodes.filter(function(n) {
      return n && !n.isStream && (n.type & PwNodeType.AudioSource) === PwNodeType.AudioSource && !root._isOwnHostedNode(String(n.name), channelSinkNames)
    })

    var playbackStreams = nodes.filter(function(n) {
      return AppsModel.isPlaybackStream(n) && !AppsModel.isChannelOwnOutputStream(n, channelSinkNames)
    })

    var streamAssignments = { master: [] }
    for (var i = 0; i < baseChannels.length; i++) streamAssignments[baseChannels[i].id] = []
    for (var j = 0; j < playbackStreams.length; j++) {
      var stream = playbackStreams[j]
      var sinkNode = root.currentSinkForStream(stream)
      var sinkName = sinkNode ? String(sinkNode.name) : ""
      var zone = "master"
      for (var k = 0; k < baseChannels.length; k++) {
        if (sinkName === "waveform_" + baseChannels[k].id) { zone = baseChannels[k].id; break }
      }
      if (!streamAssignments[zone]) streamAssignments[zone] = []
      streamAssignments[zone].push(stream)
    }

    var masterApps = streamAssignments.master || []
    var channels = baseChannels.map(function(c) {
      return { id: c.id, name: c.name, type: c.type, device: c.device, status: c.status, eq: c.eq, node: c.node, outputNode: c.outputNode,
        eqControlNode: c.eqControlNode, apps: streamAssignments[c.id] || [], color: root.channelColorFor(c.id) }
    })

    root.baseChannels = baseChannels
    root.channelSinkNames = channelSinkNames
    root.realOutputDevices = realOutputDevices
    root.realInputDevices = realInputDevices
    root.playbackStreams = playbackStreams
    root.streamAssignments = streamAssignments
    root.masterApps = masterApps
    root.channels = channels
  }

  // Repeater-stable snapshots — MixerView's Repeaters bind to these, never
  // to `channels`/`masterApps` above directly. Even throttled to
  // _recomputePipewireDerived's own cadence, those are still reassigned as
  // brand-new arrays (and new per-channel objects) on every recompute, and
  // feeding that straight into a Repeater's `model:` treats every one as
  // "the whole list changed," tearing down and rebuilding every
  // ChannelColumn/AppPill delegate. Mid-drag, that destroys the very
  // AppPill the user's mouse has grabbed — confirmed directly via logging:
  // the dragged pill's dragGhost reference went null in clusters that line
  // up exactly with this happening, only for channel-origin drags (MASTER
  // isn't inside the outer Repeater, so it was insulated from the outer
  // rebuild). This is the same class of issue the built-in Audio panel's
  // own snapshot-timer/displayAudioStreams pattern exists to avoid (see its
  // Panel.qml comment on displayAudioSinks/displayAudioStreams).
  property var displayChannels: []
  property var displayMasterApps: []
  // {id, name} pairs for ChannelMix's two side-chip Repeaters — same
  // stability requirement as displayChannels/displayMasterApps above.
  property var displayMixSideA: []
  property var displayMixSideB: []

  function _refreshDisplaySnapshots() {
    root._recomputePipewireDerived()
    root.displayChannels = root.channels
    root.displayMasterApps = root.masterApps
    root.displayMixSideA = root.mixSideA.map(function(id) { return { id: id, name: root.channelById(id).name, color: root.channelColorFor(id) } })
    root.displayMixSideB = root.mixSideB.map(function(id) { return { id: id, name: root.channelById(id).name, color: root.channelColorFor(id) } })
  }

  // Mirrors MixerView's shared DragGhost's own visibility (AppPill already
  // flips it on drag start/stop) so the snapshot refresh below can freeze
  // itself for as long as any pill anywhere is actively being dragged —
  // guaranteeing a PipeWire tick mid-drag can never rebuild the delegate
  // the user is currently holding.
  readonly property bool dragInProgress: !!(contentLoader.item
    && contentLoader.item.exposedDragGhost && contentLoader.item.exposedDragGhost.visible)

  onDragInProgressChanged: if (!root.dragInProgress) root._refreshDisplaySnapshots()

  // Gated on root.opened: nothing reads any of this cascade's output while
  // the panel is closed (every consumer is inside the popup, or a Timer
  // that's separately gated on its own real condition below), so ticking
  // this every 150ms while closed was pure waste. The onOpenedChanged
  // handler above gives an immediate refresh on open rather than waiting
  // up to 150ms for the first tick, so the panel never shows a stale first
  // frame.
  Timer {
    interval: 150
    running: root.opened
    repeat: true
    onTriggered: if (!root.dragInProgress) root._refreshDisplaySnapshots()
  }

  Component.onCompleted: { root._refreshDisplaySnapshots(); root._checkDependencies() }

  function channelById(id) {
    for (var i = 0; i < channels.length; i++)
      if (channels[i].id === id) return channels[i]
    return null
  }

  // Applies an EQ curve change live, with zero process restart — see
  // ChannelManager.setChannelEq's comment for why that matters (a restart
  // recreates the channel's sink and was pausing whatever app was routed to
  // it). PipeWire's filter-chain module exposes every LV2 control port as a
  // live-settable "Props" param on the channel's own node (confirmed via
  // `pw-cli enum-params <id> Props` — "eq:g_4" etc. show up right next to
  // the node's ordinary volume/mute props), so this just needs the
  // channel's already-resolved PwNode id and a `pw-cli set-param` call
  // setting every band's gain in one batched Props update. Lightly
  // debounced (not for audio-safety reasons like the old restart-based
  // approach — there's no disruption to avoid — just to avoid spawning a
  // pw-cli process on every single pointer-move tick of a fast drag).
  property var _eqLiveApplyQueue: ({}) // channelId -> bands, pending application

  Timer {
    id: eqLiveApplyTimer
    interval: 40
    repeat: false
    onTriggered: root._flushEqLiveApply()
  }

  function applyEqLive(channelId, bands) {
    var next = Object.assign({}, root._eqLiveApplyQueue)
    next[channelId] = bands
    root._eqLiveApplyQueue = next
    eqLiveApplyTimer.restart()
  }

  function _flushEqLiveApply() {
    var pending = root._eqLiveApplyQueue
    root._eqLiveApplyQueue = {}
    for (var channelId in pending) {
      var channel = root.channelById(channelId)
      if (!channel || !channel.eqControlNode) continue
      var bands = EqBands.normalizeBands(pending[channelId])
      var parts = []
      for (var i = 0; i < bands.length; i++) {
        parts.push("\"eq:g_" + i + "\"")
        parts.push(EqBands.dbToLinearGain(bands[i]).toFixed(6))
      }
      var pod = "{ params = [ " + parts.join(" ") + " ] }"
      root._runEqLiveApply(channelId, ["pw-cli", "set-param", String(channel.eqControlNode.id), "Props", pod])
    }
  }

  // Own function (not inlined in the loop above) so each call gets its own
  // freshly-bound `channelId`/`proc` parameters — a closure declared
  // directly inside a `for...in` loop body would instead close over the
  // loop's shared `var` bindings, and every callback would see whatever
  // channelId/proc the loop last landed on by the time it actually fires.
  function _runEqLiveApply(channelId, cmd) {
    var proc = eqLiveApplyProcComponent.createObject(root, { command: cmd })
    proc.exited.connect(function(exitCode, exitStatus) {
      if (exitCode !== 0) console.warn("waveform: live EQ apply failed for", channelId, "exit", exitCode)
      proc.destroy()
    })
    proc.running = true
  }

  Component { id: eqLiveApplyProcComponent; Process {} }

  // ---------------------------------------------------------------- ChannelMix
  //
  // SteelSeries Sonar's "ChatMix" generalized to any user-chosen group of
  // channels on each side (not hardcoded to game/chat, and not limited to
  // one channel per side — see the plan's ChannelMix section). Each
  // channel's own fader is never touched: the fade is applied entirely to a
  // second, independent volume control every channel already has — its
  // `_output` node (the post-EQ playback stream feeding the real device),
  // confirmed directly to be a distinct, separately-writable
  // PwNodeAudioIface from the fader's capture-side node (`pactl
  // set-sink-volume` on one has zero effect on the other). That means this
  // needs no feedback guard, no base-volume snapshot, none of the
  // read-back-and-reconcile complexity the first version had — it's a
  // plain one-way multiply, always safe to just write.
  //
  // Membership (which channels are on which side) persists
  // (ChannelManager.channelMixSideA/B); the fade position itself is
  // transient and always resets to centered on a fresh load.

  // Filtered against the live channel list so a deleted channel just quietly
  // drops out rather than needing active pruning of the persisted arrays.
  readonly property var mixSideA: channelManager.channelMixSideA.filter(function(id) { return !!root.channelById(id) })
  readonly property var mixSideB: channelManager.channelMixSideB.filter(function(id) { return !!root.channelById(id) })

  property real channelMixT: 0 // -1..1, 0 = centered/no effect

  // Which single channel's device dropdown is currently open, if any —
  // owned centrally rather than as local state on each DeviceDropdown so
  // opening one always closes any other that was already open (previously
  // each dropdown tracked its own `expanded` independently and two could
  // be open — and visually overlapping — at once).
  property string openDeviceDropdownChannelId: ""

  function setChannelMixT(t) {
    root.channelMixT = Math.max(-1, Math.min(1, Number(t) || 0))
  }

  // Moves a channel onto side "a"/"b", or off ChannelMix entirely
  // (`side` null/anything else) — removing it from whichever side it was
  // on first, so a channel can only ever be on one side at a time. Leaving
  // ChannelMix resets that channel's output-node volume back to neutral
  // immediately, synchronously, rather than waiting for the next poll tick
  // to notice it's no longer in either group. If either side ends up empty
  // (including via this removal), the fade position itself resets to
  // centered too — otherwise a slider left at, say, 70% toward a now-empty
  // side stayed stuck there both visually and functionally: dragging it
  // did nothing (the knob is correctly disabled while `!active`, see
  // ChannelMixBar.qml), and the *next* channel dropped onto that side would
  // immediately inherit the stale skew instead of starting neutral.
  function assignChannelMixSide(channelId, side) {
    if (!channelId) return
    var nextA = channelManager.channelMixSideA.filter(function(id) { return id !== channelId })
    var nextB = channelManager.channelMixSideB.filter(function(id) { return id !== channelId })
    if (side === "a") nextA.push(channelId)
    else if (side === "b") nextB.push(channelId)
    else root._resetChannelMixOutput(channelId)
    channelManager.setChannelMixGroups(nextA, nextB)
    if (nextA.length === 0 || nextB.length === 0) root.channelMixT = 0
  }

  function _resetChannelMixOutput(channelId) {
    var channel = root.channelById(channelId)
    if (channel && channel.outputNode && channel.outputNode.audio) channel.outputNode.audio.volume = 1.0
  }

  // Attenuate-only, never boost: the side being faded *toward* stays at
  // exactly 1.0 (its own already-set volume, untouched) and the side being
  // faded *away from* ramps down to fully silent at the far end. Multiplying
  // a channel's already-100%-set output up toward `_mixCeilFactor` (an
  // earlier version went to 1.5, i.e. 150%) was a real bug, not a tuning
  // nitpick: it pushed already-hot channels into audible distortion/
  // clipping, and made the live peak meter (which watches this same
  // post-mix output node) visibly overshoot past the fader's own knob
  // position — the meter was reporting the true, boosted level correctly,
  // the boost itself just should never have been happening. A "fader
  // between two channels" fades one out, it doesn't turn the other one up.
  function _mixFactorFor(side) {
    var t = root.channelMixT
    var raw = side === "a" ? (t <= 0 ? 1 : 1 - t) : (t >= 0 ? 1 : 1 + t)
    return Math.max(0, Math.min(1, raw))
  }

  Timer {
    id: channelMixTimer
    interval: 120
    repeat: true
    running: root.mixSideA.length > 0 || root.mixSideB.length > 0
    onTriggered: {
      var factorA = root._mixFactorFor("a"), factorB = root._mixFactorFor("b")
      for (var i = 0; i < root.mixSideA.length; i++) root._applyChannelMixVolume(root.mixSideA[i], factorA)
      for (var j = 0; j < root.mixSideB.length; j++) root._applyChannelMixVolume(root.mixSideB[j], factorB)
    }
  }

  function _applyChannelMixVolume(channelId, factor) {
    var channel = root.channelById(channelId)
    if (!channel || !channel.outputNode || !channel.outputNode.audio) return
    if (Math.abs(channel.outputNode.audio.volume - factor) > 0.002) channel.outputNode.audio.volume = factor
  }

  // Drop handler shared by MASTER's and every channel's AppsDropZone.
  function routeStreamToZone(streamNode, zoneId) {
    if (!streamNode) return
    var pactlIndex = AppsModel.pactlIndexForStream(streamNode)
    if (!pactlIndex) {
      console.warn("waveform: stream has no object.serial yet, cannot route", streamNode.name)
      return
    }
    var matchKey = AppsModel.matchKeyForStream(streamNode)
    routingManager.routeStream(pactlIndex, matchKey, zoneId)
  }

  // A channel just created won't have a live sink for a moment (matches the
  // speaker-tuning service's own settle time, well under a second in
  // practice). Poll while any channel is pending; give up and roll one back
  // if its sink never shows up.
  readonly property int channelStartupTimeoutMs: 8000

  function _reconcilePendingChannels() {
    var now = Date.now()
    var list = channelManager.channels
    for (var i = 0; i < list.length; i++) {
      var c = list[i]
      if (c.status !== "pending") continue
      var userNode = c.type === "input" ? root.findNodeByName("waveform_" + c.id) : root.findSinkByName("waveform_" + c.id)
      if (userNode) {
        channelManager.markChannelActive(c.id)
      } else if (now - (c.createdAt || now) > root.channelStartupTimeoutMs) {
        console.warn("waveform: channel", c.id, "never came up, rolling back")
        channelManager.deleteChannel(c.id)
      }
    }
  }

  Timer {
    interval: 300
    running: root.channels.some(function(c) { return c.status === "pending" })
    repeat: true
    onTriggered: root._reconcilePendingChannels()
  }

  // Keeps every routed app pinned to its assigned channel — see
  // RoutingManager's header comment for why this replaced a
  // WirePlumber-restart-based mechanism. Runs continuously (not gated on
  // the popup being open): the whole point is that routing holds while
  // you're not even looking at the mixer, and that a paused/reopened app
  // (a fresh stream node once it un-pauses) gets caught again quickly.
  function _reconcileAppRouting() {
    for (var i = 0; i < root.playbackStreams.length; i++) {
      var stream = root.playbackStreams[i]
      var matchKey = AppsModel.matchKeyForStream(stream)
      if (!matchKey) continue
      var pactlIndex = AppsModel.pactlIndexForStream(stream)
      if (!pactlIndex) continue
      var sinkNode = root.currentSinkForStream(stream)
      var sinkName = sinkNode ? String(sinkNode.name) : ""
      routingManager.reconcileStream(pactlIndex, matchKey, sinkName)
    }
  }

  Timer {
    interval: 1500
    running: Object.keys(routingManager.appAssignments).length > 0
    repeat: true
    onTriggered: {
      root._reconcileAppRouting()
      routingManager.pruneStaleAssignments()
    }
  }

  function openEq(channelId) {
    root.activeChannelId = channelId
    root.activeView = "eq"
  }
  function backToMixer() {
    root.activeView = "mixer"
  }

  function openPanel() { panel.open = true }
  function closePanel() {
    panel.open = false
    root.activeView = "mixer"
    root.openDeviceDropdownChannelId = ""
  }
  function togglePanel() { panel.open ? closePanel() : openPanel() }

  // Bar-widget contract for hotkey/summon routing (Bar.findPanelWidget wants
  // open/close/opened on the bar-widget root).
  readonly property bool opened: panel.open
  function open() { openPanel() }
  function close() { closePanel() }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root, direction)
    return false
  }

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // Keeps Pipewire from tearing down these nodes' bound properties while
  // the panel references them — same pattern as the built-in Audio panel.
  PwObjectTracker {
    objects: [root.masterSink]
      .concat(root.channels.map(function(c) { return c.node }))
      .concat(root.channels.map(function(c) { return c.outputNode }))
      .concat(root.channels.map(function(c) { return c.eqControlNode }))
      .concat(root.playbackStreams)
      .filter(function(n) { return !!n })
  }

  ChannelManager {
    id: channelManager
    // Recomputes the derived cascade immediately on any topology change
    // (create/delete/rename/status/device/eq) instead of waiting for the
    // next 150ms tick — preserves the instant-update behavior this had
    // when the cascade was still a live reactive binding, for everything
    // that reads root.channels/baseChannels/etc. directly (not just the
    // Repeater-facing displayChannels snapshot, which was already only
    // ever refreshed on the same ~150ms cadence via the Timer below).
    onChannelsChanged: root._recomputePipewireDerived()
    defaultSinkName: root.masterSink ? String(root.masterSink.name) : ""
    defaultSourceName: root.masterSource ? String(root.masterSource.name) : ""
  }

  RoutingManager {
    id: routingManager
    defaultSinkName: root.masterSink ? String(root.masterSink.name) : ""
    validChannelIds: root.baseChannels.map(function(c) { return c.id })
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // Nerd Font Material Design Icons "tune-vertical" (md-tune_vertical,
    // U+F066A) — a mixing-board glyph, vertical fader tracks each with a
    // dot, replacing the generic 🎚 emoji. Uses `bar.fontFamily`
    // automatically (WidgetButton's own default), same Nerd Font already
    // rendering the mute/volume icons elsewhere in this plugin.
    text: "󰙪"
    fontSize: Style.font.body
    horizontalMargin: 8
    tooltipText: "Waveform"
    onPressed: root.togglePanel()
  }

  IpcHandler {
    target: "jmthomas00.waveform"

    function open(): void { root.openPanel() }
    function close(): void { root.closePanel() }
    function toggle(): void { root.togglePanel() }
  }

  // Which bar section (left/center/right) this widget's own icon currently
  // sits in — read from shell.json's persisted layout via `bar.layoutConfig`
  // (`{left:[{id},...], center:[...], right:[...]}`, confirmed directly by
  // reading a live ~/.config/omarchy/shell.json), the same source
  // `plugins/bar/widgets/Tray.qml` reads for its own (unrelated) ownership
  // check — there's no `bar.section`/`bar.region` property handed to a
  // widget directly. Reactive: `layoutConfig` itself updates when the user
  // drags an icon to a different section, so this follows without needing
  // a restart.
  function _currentBarSection() {
    var layout = root.bar && root.bar.layoutConfig ? root.bar.layoutConfig : null
    if (!layout) return "center"
    var sections = ["left", "center", "right"]
    for (var i = 0; i < sections.length; i++) {
      var list = layout[sections[i]]
      if (!Array.isArray(list)) continue
      for (var j = 0; j < list.length; j++) {
        if (list[j] && list[j].id === root.moduleName) return sections[i]
      }
    }
    return "center"
  }
  readonly property string barSection: root._currentBarSection()

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    // Mimics the native bar plugins' own left/center/right popup placement
    // convention: a center-section icon centers on the whole screen
    // (`centerOnBar: true`, unchanged from before); a left/right-section
    // icon instead centers under its own icon position and lets
    // KeyboardPanel's existing screen-edge clamp (`cardOrigin`, see
    // KeyboardPanel.qml) pull it flush to that edge — confirmed directly,
    // reading every built-in plugin, that this incidental clamp (not a
    // dedicated three-way alignment mode — no such thing exists natively
    // either) is genuinely the whole mechanism behind the behavior being
    // matched here.
    centerOnBar: root.barSection === "center"
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(root.mixerContentWidth)
    contentHeight: panel.fittedContentHeight(
      contentLoader.item ? contentLoader.item.implicitHeight : Style.space(360),
      Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.closePanel()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Loader {
        id: contentLoader
        width: parent.width
        sourceComponent: root.activeView === "eq" ? eqViewComponent : mixerViewComponent
      }

      Component {
        id: mixerViewComponent
        MixerView {
          bar: root.bar
          masterSink: root.masterSink
          panelOpen: root.opened
          channels: root.displayChannels
          masterApps: root.displayMasterApps
          presets: channelManager.visiblePresets
          channelMixSideA: root.displayMixSideA
          channelMixSideB: root.displayMixSideB
          channelMixT: root.channelMixT
          realOutputDevices: root.realOutputDevices
          realInputDevices: root.realInputDevices
          openDeviceDropdownChannelId: root.openDeviceDropdownChannelId
          addMicAccentColor: root.channelColorFor("__waveform_add_mic__")
          lspEqAvailable: root.lspEqAvailable
          onChannelHeaderClicked: function(channelId) { root.openEq(channelId) }
          onAddChannelRequested: function(type) {
            var count = channelManager.channels.filter(function(c) { return c.type === type }).length + 1
            var label = type === "input" ? "Mic " + count : "Channel " + count
            channelManager.createChannel(label, type)
          }
          onChannelDeleteRequested: function(channelId) { channelManager.deleteChannel(channelId) }
          onChannelRenameRequested: function(channelId, newName) { channelManager.renameChannel(channelId, newName) }
          onAppDropped: function(streamNode, zoneId) { root.routeStreamToZone(streamNode, zoneId) }
          onChannelMixBalanceDragged: function(t) { root.setChannelMixT(t) }
          onChannelMixAssignRequested: function(channelId, side) { root.assignChannelMixSide(channelId, side) }
          onChannelDeviceRequested: function(channelId, deviceName) { channelManager.setChannelDevice(channelId, deviceName) }
          onDeviceDropdownToggleRequested: function(channelId) {
            root.openDeviceDropdownChannelId = root.openDeviceDropdownChannelId === channelId ? "" : channelId
          }
          onDeviceDropdownCloseRequested: root.openDeviceDropdownChannelId = ""
          onChannelReorderRequested: function(draggedId, targetId) { channelManager.reorderChannel(draggedId, targetId) }
          onImplicitWidthChanged: root.mixerContentWidth = implicitWidth
          Component.onCompleted: root.mixerContentWidth = implicitWidth
        }
      }

      Component {
        id: eqViewComponent
        EqView {
          bar: root.bar
          channel: root.channelById(root.activeChannelId)
          presets: channelManager.visiblePresets
          viewWidth: root.mixerContentWidth
          cavaAvailable: root.cavaAvailable
          onBackRequested: root.backToMixer()
          onBandsChanged: function(channelId, bands) {
            root.applyEqLive(channelId, bands)
            channelManager.setChannelEq(channelId, bands, null)
          }
          onPresetSelected: function(channelId, presetId, bands) {
            root.applyEqLive(channelId, bands)
            channelManager.setChannelEq(channelId, bands, presetId)
          }
          onPresetSaveRequested: function(channelId, name, bands) {
            var presetId = channelManager.savePreset(name, bands)
            if (!presetId) return
            root.applyEqLive(channelId, bands)
            channelManager.setChannelEq(channelId, bands, presetId)
          }
          onPresetDeleteRequested: function(presetId) { channelManager.deletePreset(presetId) }
        }
      }
    }
  }
}
