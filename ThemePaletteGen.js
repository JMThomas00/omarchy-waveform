.pragma library

// The "vivid" slots from the active theme's colors.toml. Confirmed by
// reading every theme shipped under /usr/share/omarchy/themes/*/colors.toml
// (22 of them, including the two Waveform happened to be developed
// against): none use a numeric `color1..color14` scheme — that was this
// plugin's own earlier, wrong assumption (see the plan's Theming section,
// corrected alongside this file). Every shipped theme instead uses this
// named ANSI-style set, so it's the primary key list; the numeric set is
// kept as a fallback only in case some future/custom theme uses it.
var NAMED_KEYS = [
  "red", "yellow", "orange", "green", "cyan", "blue", "magenta", "brown",
  "bright_red", "bright_yellow", "bright_green", "bright_cyan", "bright_blue", "bright_magenta"
]
var NUMERIC_KEYS = [
  "color1", "color2", "color3", "color4", "color5", "color6",
  "color9", "color10", "color11", "color12", "color13", "color14"
]

function luminance(hex) {
  var r = parseInt(hex.substr(1, 2), 16) / 255
  var g = parseInt(hex.substr(3, 2), 16) / 255
  var b = parseInt(hex.substr(5, 2), 16) / 255
  return 0.299 * r + 0.587 * g + 0.114 * b
}

// Same line-matching approach as Color.qml's own loadColors.
function extractByKeys(raw, keys) {
  var found = {}
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var match = lines[i].match(/^\s*([A-Za-z0-9_-]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})/)
    if (!match) continue
    if (keys.indexOf(match[1]) !== -1) found[match[1]] = match[2]
  }
  var hexes = []
  for (var k = 0; k < keys.length; k++) {
    if (found[keys[k]]) hexes.push(found[keys[k]])
  }
  return hexes
}

// Returns hex strings sorted darkest -> lightest.
function parseSortedPalette(raw) {
  var hexes = extractByKeys(raw, NAMED_KEYS)
  if (hexes.length < 2) hexes = extractByKeys(raw, NUMERIC_KEYS)
  hexes.sort(function(a, b) { return luminance(a) - luminance(b) })
  return hexes
}

// Simple DJB2-style string hash — deterministic across runs/reloads (not
// Math.random, not object identity), which is the whole point: a channel's
// color needs to come out the same every time for the same id, including
// after a shell restart or reordering the channel list. `| 0` keeps it a
// 32-bit int; Math.abs so it's safe to use with `%`.
function stableHash(str) {
  var s = String(str || "")
  var hash = 5381
  for (var i = 0; i < s.length; i++) {
    hash = ((hash << 5) + hash + s.charCodeAt(i)) | 0
  }
  return Math.abs(hash)
}

// Which palette slot a given id should use — hashed off the id itself, not
// list position, so deleting one channel never reshuffles the colors of
// the ones that are left (see the plan's Theming section).
function colorIndexForId(id, paletteLength) {
  if (!paletteLength) return 0
  return stableHash(id) % paletteLength
}
