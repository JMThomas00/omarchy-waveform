.pragma library

function confName(channelId) {
  return "waveform-channel-" + channelId + ".conf"
}

function unitName(channelId) {
  return "waveform-channel-" + channelId + ".service"
}

// Same shape as /usr/share/omarchy/default/systemd/user/omarchy-speaker-tuning.service:
// a hosted PipeWire *client* process (not a pipewire.conf.d daemon drop-in),
// so this one channel can be created/destroyed without touching any other
// audio on the system, and so a bad channel config only breaks its own unit.
function renderUnit(channel) {
  return [
    "[Unit]",
    "Description=Waveform channel: " + String(channel.name || "").replace(/[\r\n]+/g, " "),
    "After=pipewire.service wireplumber.service",
    "Requires=pipewire.service",
    "Wants=wireplumber.service",
    "PartOf=pipewire.service",
    "",
    "[Service]",
    "Type=simple",
    "ExecStart=/usr/bin/pipewire -c " + confName(channel.id),
    "Restart=on-failure",
    "RestartSec=2",
    "",
    "[Install]",
    "WantedBy=graphical-session.target",
    ""
  ].join("\n")
}
