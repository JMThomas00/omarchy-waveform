.pragma library

// Prebuilt EQ presets, matching EqBands.BANDS' 12-band order (20/31/62/125/
// 250/500/1k/2k/4k/8k/16k/20k — upgraded from the original 6, curves
// redrawn at the new resolution to keep each preset's shape/character
// rather than just zero-padding the old 6 values onto the new bottom half
// of the spectrum). A plain JS module rather than a bundled .json file —
// QML has no direct `import "x.json"` for static data, and this avoids the
// async-file-read complexity of loading one at runtime for something this
// small and fixed.

var PRESETS = [
  { id: "flat", name: "Flat", bands: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] },
  { id: "bass_boost", name: "Bass Boost", bands: [6, 6, 5, 4, 2, 1, 0, 0, 0, 0, 0, 0] },
  { id: "vocal_clarity", name: "Vocal Clarity", bands: [-2, -2, -1, -1, 0, 1, 3, 4, 3, 1, 0, 0] },
  { id: "treble_boost", name: "Treble Boost", bands: [0, 0, 0, 0, 0, 0, 0, 1, 3, 5, 6, 6] },
  { id: "v_shape", name: "V-Shape", bands: [5, 5, 4, 2, -1, -3, -3, -1, 2, 4, 5, 5] },
  { id: "movie_immersion", name: "Movie: Immersion", bands: [4, 4, 3, 2, 0, -1, -1, 0, 1, 2, 3, 3] }
]

// User-facing preset list: prebuilt defaults minus any the user has
// deleted, plus whatever they've saved themselves. Order is defaults-then-
// custom so the picker doesn't reshuffle every time someone saves a new
// one. `customPresets`/`deletedDefaultIds` come from ChannelManager's
// state.json-backed storage — this stays a pure function so it's testable
// without any file/process I/O.
function mergePresets(customPresets, deletedDefaultIds) {
  var deleted = {}
  ;(deletedDefaultIds || []).forEach(function(id) { deleted[id] = true })
  var visibleDefaults = PRESETS.filter(function(p) { return !deleted[p.id] })
  return visibleDefaults.concat(customPresets || [])
}

function findPresetIn(id, presets) {
  for (var i = 0; i < presets.length; i++) if (presets[i].id === id) return presets[i]
  return null
}

// A deleted default (or any other no-longer-resolvable id) just falls back
// to "Custom" — the channel's bands are untouched, it simply isn't labeled
// with a preset name anymore, same as any hand-dragged curve.
function presetNameForIn(presetId, presets) {
  if (!presetId) return "Custom"
  var preset = findPresetIn(presetId, presets)
  return preset ? preset.name : "Custom"
}
