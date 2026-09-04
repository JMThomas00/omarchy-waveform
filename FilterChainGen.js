.pragma library
.import "EqBands.js" as EqBands

// Renders one channel's hosted-client PipeWire config: host boilerplate
// (identical to /usr/share/omarchy/default/audio/filter-chain-host.conf)
// plus a single libpipewire-module-filter-chain block whose capture side is
// the channel's virtual sink and whose filter graph is the channel's EQ —
// one artifact does both jobs (see the plan's Architecture section).
//
// The filter graph is a single LSP "Parametric Equalizer x16 Stereo" LV2
// node (http://lsp-plug.in/plugins/lv2/para_equalizer_x16_stereo — upgraded
// from the x8 variant to fit EqBands.BANDS' 12 fixed-frequency bands),
// driving them via LSP's per-band control ports (confirmed directly from
// the plugin's own para_equalizer_x16_stereo.ttl, not guessed — port
// symbols follow "<field>_<bandNumber>", e.g. "f_0"/"g_0"/"q_0" for band
// 0's frequency/gain/Q; this variant is 0-indexed, unlike x8's 1-indexed
// bands). Bands 12-15 (unused — this UI only exposes 12) are left off
// (ft_12 = ft_13 = ft_14 = ft_15 = 0).

function escapeConfString(value) {
  return String(value === undefined || value === null ? "" : value)
    .replace(/\\/g, "\\\\")
    .replace(/"/g, "\\\"")
}

function sinkNodeName(channelId) {
  return "waveform_" + channelId
}

// One band's control-port block for the LSP EQ (ft/fm/s = filter
// type/mode/slope; f/w/g/q = frequency/width/gain/Q). Every band uses
// Bell (type 1) with RLC(BT) mode and a fixed Q — not user-editable in
// this milestone, only gain is (see EqBands.js).
function renderBandControls(bandNumber, freqHz, gainDb) {
  var n = String(bandNumber)
  var gain = EqBands.dbToLinearGain(gainDb).toFixed(6)
  return [
    "                \"ft_" + n + "\" = 1",
    "                \"fm_" + n + "\" = 0",
    "                \"s_" + n + "\" = 0",
    "                \"f_" + n + "\" = " + freqHz.toFixed(3),
    "                \"w_" + n + "\" = 4.0",
    "                \"g_" + n + "\" = " + gain,
    "                \"q_" + n + "\" = 1.0"
  ].join("\n")
}

function renderEqControlBlock(bands) {
  var normalized = EqBands.normalizeBands(bands)
  var lines = []
  for (var i = 0; i < EqBands.BANDS.length; i++) {
    lines.push(renderBandControls(i, EqBands.BANDS[i].freq, normalized[i]))
  }
  // Bands 12-15 exist on the x16 plugin but aren't exposed by this UI — off.
  lines.push("                \"ft_12\" = 0")
  lines.push("                \"ft_13\" = 0")
  lines.push("                \"ft_14\" = 0")
  lines.push("                \"ft_15\" = 0")
  return lines.join("\n")
}

// Output channels: apps play INTO this channel, so the *capture* side is
// the user-facing node (a real Audio/Sink named "waveform_<id>", exactly
// what a playback app picks from its own output-device list) and the
// *playback* side is the hidden one wired to the real output device
// (target.object = the chosen speaker/headphones, node.dont-move/
// dont-fallback/linger so it stays put — see the dell-xps-2026 tuning
// precedent this whole hosted-client pattern is based on).
function renderOutputRouting(nodeName, target) {
  return [
    "            capture.props = {",
    "                node.name   = \"" + nodeName + "\"",
    "                media.class = Audio/Sink",
    "            }",
    "            playback.props = {",
    "                node.name          = \"" + nodeName + "_output\"",
    "                node.passive       = true",
    "                target.object      = \"" + target + "\"",
    "                node.dont-move     = true",
    "                node.dont-fallback = true",
    "                node.linger        = true",
    "            }"
  ].join("\n")
}

// Input (mic) channels: the roles reverse. The *capture* side is the
// hidden one wired to the real input device (target.object = the chosen
// mic, same dont-move/dont-fallback/linger flags — now on capture.props
// since that's the side touching real hardware) and the *playback* side is
// the user-facing node: a virtual Audio/Source named "waveform_<id>" that
// other apps (Discord, OBS, a game) pick from their own microphone list,
// carrying this channel's EQ'd result. Confirmed directly against a real
// local example for this exact reversed shape — PipeWire's own shipped
// `/usr/share/pipewire/filter-chain/source-duplicate-FL.conf` builds a
// virtual mic the same way: capture.props with no media.class (a plain
// capture stream) + playback.props with media.class = "Audio/Source" — the
// "Mic-type channel filter-chain shape" the plan's Known Risks section
// flagged as needing a local worked example before this could be built.
function renderInputRouting(nodeName, target) {
  return [
    "            capture.props = {",
    "                node.name          = \"" + nodeName + "_capture\"",
    "                node.passive       = true",
    "                target.object      = \"" + target + "\"",
    "                node.dont-move     = true",
    "                node.dont-fallback = true",
    "                node.linger        = true",
    "            }",
    "            playback.props = {",
    "                node.name   = \"" + nodeName + "\"",
    "                media.class = Audio/Source",
    "            }"
  ].join("\n")
}

function renderChannelConf(channel) {
  var nodeName = sinkNodeName(channel.id)
  var description = escapeConfString(channel.name)
  var target = escapeConfString(channel.device)
  var bands = channel.eq && channel.eq.bands ? channel.eq.bands : EqBands.flatBands()
  var routing = channel.type === "input" ? renderInputRouting(nodeName, target) : renderOutputRouting(nodeName, target)

  var lines = [
    "# Generated by the Waveform plugin — do not edit by hand.",
    "# Regenerated whenever this channel's name, device, or EQ changes.",
    "",
    "context.properties = {",
    "    log.level = 0",
    "}",
    "",
    "context.spa-libs = {",
    "    audio.convert.* = audioconvert/libspa-audioconvert",
    "    support.*       = support/libspa-support",
    "}",
    "",
    "context.modules = [",
    "    { name = libpipewire-module-rt",
    "        args = { }",
    "        flags = [ ifexists nofail ]",
    "    }",
    "    { name = libpipewire-module-protocol-native }",
    "    { name = libpipewire-module-client-node }",
    "    { name = libpipewire-module-adapter }",
    "    { name = libpipewire-module-filter-chain",
    "        args = {",
    "            node.description = \"" + description + "\"",
    "            media.name       = \"" + description + "\"",
    "",
    "            filter.graph = {",
    "                nodes = [",
    "                    { type = lv2",
    "                        name = eq",
    "                        plugin = \"http://lsp-plug.in/plugins/lv2/para_equalizer_x16_stereo\"",
    "                        control = {",
    renderEqControlBlock(bands),
    "                        }",
    "                    }",
    "                ]",
    "                inputs  = [ \"eq:in_l\" \"eq:in_r\" ]",
    "                outputs = [ \"eq:out_l\" \"eq:out_r\" ]",
    "            }",
    "",
    "            audio.channels = 2",
    "            audio.position = [ FL FR ]",
    "",
    routing,
    "        }",
    "    }",
    "]",
    ""
  ]

  return lines.join("\n")
}
