.pragma library

// Minimal stream-identification helpers, adapted from the built-in Audio
// panel's Model.js (/usr/share/omarchy/shell/plugins/panels/audio/Model.js)
// — just the parts Waveform needs (no MPRIS label-matching sophistication).

function isPlaybackStream(node) {
  if (!node || !node.isStream) return false
  if (node.isSink === true) return true
  var mediaClass = String(node.type || "")
  return mediaClass.indexOf("Stream/Output/Audio") !== -1
    || mediaClass.indexOf("AudioOutStream") !== -1
    || mediaClass.indexOf("Output") !== -1
}

// Every Waveform channel's hosted filter-chain client has its OWN internal
// playback stream feeding the physical device (node.name "waveform_<id>
// _output") — it satisfies isPlaybackStream() above (isSink is true on it,
// same as a real app stream) but it's the channel's own plumbing, not an
// application. Left unfiltered, a channel's own name/EQ-processed audio
// shows up as if it were an "app" pill sitting in whichever zone its
// target device resolves to (almost always MASTER, since it targets a
// physical device) — confirmed directly: a channel named "Gaming" appeared
// as a pill labeled "Gaming" under MASTER's Apps zone the moment it was
// created, with nothing dragged anywhere.
function isChannelOwnOutputStream(node, channelSinkNames) {
  if (!node) return false
  var name = String(node.name || "")
  for (var i = 0; i < channelSinkNames.length; i++) {
    if (name === channelSinkNames[i] + "_output") return true
  }
  return false
}

function nodeProps(node) {
  return node && node.ready && node.properties ? node.properties : {}
}

function streamLabel(node) {
  if (!node) return "Stream"
  var p = nodeProps(node)
  return p["application.name"] || node.description || p["media.name"] || node.name || "Stream"
}

// Used as the WirePlumber stream.rules match key, so routing persists
// across an app relaunch. Streams that don't carry application.name (rare)
// still get live drag-and-drop routing — they just won't stick after the
// app restarts.
function matchKeyForStream(node) {
  var p = nodeProps(node)
  var name = p["application.name"]
  return name ? String(name) : null
}

// The numeric id `pactl move-sink-input` needs (what pactl itself calls
// "index") is PipeWire-pulse's own bookkeeping number, exposed as the
// object.serial property — NOT Quickshell's PwNode.id, which is PipeWire's
// *native* object.id instead. The two are different numbers for the same
// node (confirmed directly: object.id=119 / object.serial=1528 for the same
// stream) — passing PwNode.id straight to `pactl move-sink-input` silently
// targets nothing and the move is a no-op.
function pactlIndexForStream(node) {
  var p = nodeProps(node)
  var serial = p["object.serial"]
  return serial ? String(serial) : null
}
