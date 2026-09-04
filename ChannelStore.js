.pragma library
.import "EqBands.js" as EqBands

// Pure data helpers for Waveform's channel list — no file/process I/O here
// (that lives in ChannelManager.qml, which is the only place Quickshell's
// Process/FileView types can actually be instantiated from).

function generateId() {
  return "ch_" + Date.now().toString(36) + Math.floor(Math.random() * 1e9).toString(36)
}

function generatePresetId() {
  return "custom_" + Date.now().toString(36) + Math.floor(Math.random() * 1e9).toString(36)
}

// `device` is the target device's PipeWire node name (e.g. the current
// default sink/source at creation time) — see FilterChainGen's
// target.object. `type` is "output" (apps play into it, feeds a real
// output device — e.g. speakers/headphones) or "input" (captures from a
// real input device — e.g. a mic — and exposes the EQ'd result as a
// virtual source apps can pick as their microphone). See
// FilterChainGen.renderChannelConf for how the two reverse which side of
// the hosted filter-chain client is the "user-facing" node vs. the one
// wired to real hardware.
function makeChannel(name, device, type) {
  return {
    id: generateId(),
    name: name,
    type: type === "input" ? "input" : "output",
    device: device,
    volume: 1.0,
    muted: false,
    eq: { presetId: "flat", bands: EqBands.flatBands() },
    status: "pending", // "pending" -> "active", or rolled back if the sink never appears
    createdAt: Date.now()
  }
}

function _stringArray(value) {
  if (!Array.isArray(value)) return []
  return value.filter(function(v) { return typeof v === "string" })
}

// state.json's full shape: channels, the user's own EQ preset customization
// (presets they've saved as `custom`, default presets they've deleted —
// `deletedDefaults`, by id, so a fresh load doesn't bring a removed default
// back), and which channels are on each side of ChannelMix (`channelMix.
// sideA`/`sideB` — arrays of channel ids, since either side can hold
// several channels grouped together; just the *membership* persists, the
// slider position itself is transient/in-memory only, see BarWidget.qml, so
// it always resets to centered on a fresh load rather than restarting
// mid-fade). All three are global, not per-channel — see the plan's Data
// model table.
function parseDocument(raw) {
  var doc = { channels: [], customPresets: [], deletedDefaultPresetIds: [], channelMixSideA: [], channelMixSideB: [] }
  if (!raw) return doc
  try {
    var parsed = JSON.parse(raw)
    if (parsed && Array.isArray(parsed.channels)) doc.channels = parsed.channels
    if (parsed && parsed.eqPresets) {
      if (Array.isArray(parsed.eqPresets.custom)) doc.customPresets = parsed.eqPresets.custom
      if (Array.isArray(parsed.eqPresets.deletedDefaults)) doc.deletedDefaultPresetIds = parsed.eqPresets.deletedDefaults
    }
    if (parsed && parsed.channelMix) {
      doc.channelMixSideA = _stringArray(parsed.channelMix.sideA)
      doc.channelMixSideB = _stringArray(parsed.channelMix.sideB)
    }
  } catch (e) {
    // Corrupt/empty state file -- start fresh rather than crash the plugin.
  }
  return doc
}

function serializeDocument(channels, customPresets, deletedDefaultPresetIds, channelMixSideA, channelMixSideB) {
  return JSON.stringify({
    version: 1,
    channels: channels,
    eqPresets: { custom: customPresets, deletedDefaults: deletedDefaultPresetIds },
    channelMix: { sideA: channelMixSideA || [], sideB: channelMixSideB || [] }
  }, null, 2) + "\n"
}
