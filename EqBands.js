.pragma library

// 12-band layout (upgraded from the original 6 — same idea, twice the
// resolution): the classic 10-band ISO graphic-EQ center frequencies
// (31/62/125/250/500/1k/2k/4k/8k/16k) bookended by 20Hz and 20kHz for full
// audible range coverage. Labels are frequency shorthand rather than named
// regions (SUB BASS/BASS/...) — with 12 points, per-band names stop being
// meaningful and every EQ plugin/graphic-EQ UI this size labels by
// frequency instead. Frequency and Q are NOT user-editable — only gain is,
// via the curve's draggable points — so they're plain constants here
// rather than part of the persisted model. Maps 1:1 onto LSP
// para_equalizer_x16_stereo's bands 0-11 (0-indexed on this plugin variant,
// unlike x8's 1-indexed bands — confirmed directly from the plugin's own
// .ttl; bands 12-15 stay off) — see FilterChainGen.js.
var BANDS = [
  { id: "b20",  label: "20",  freq: 20 },
  { id: "b31",  label: "31",  freq: 31 },
  { id: "b62",  label: "62",  freq: 62 },
  { id: "b125", label: "125", freq: 125 },
  { id: "b250", label: "250", freq: 250 },
  { id: "b500", label: "500", freq: 500 },
  { id: "b1k",  label: "1K",  freq: 1000 },
  { id: "b2k",  label: "2K",  freq: 2000 },
  { id: "b4k",  label: "4K",  freq: 4000 },
  { id: "b8k",  label: "8K",  freq: 8000 },
  { id: "b16k", label: "16K", freq: 16000 },
  { id: "b20k", label: "20K", freq: 20000 }
]

var MIN_DB = -12
var MAX_DB = 12

function flatBands() {
  return BANDS.map(function() { return 0 })
}

function clampDb(db) {
  return Math.max(MIN_DB, Math.min(MAX_DB, db))
}

// LSP's "g_N" gain port is a *linear* multiplier (0.01585..63.095749),
// not dB, despite the plugin's UI/curve working in dB — confirmed directly
// from para_equalizer_x16_stereo.ttl (units:render "%.8f G").
function dbToLinearGain(db) {
  return Math.pow(10, clampDb(db) / 20)
}

// Normalizes a possibly-missing/short/malformed bands array into exactly
// BANDS.length numbers, each clamped to [MIN_DB, MAX_DB].
function normalizeBands(bands) {
  var out = flatBands()
  if (!Array.isArray(bands)) return out
  for (var i = 0; i < out.length && i < bands.length; i++) {
    var n = Number(bands[i])
    out[i] = isFinite(n) ? clampDb(n) : 0
  }
  return out
}
