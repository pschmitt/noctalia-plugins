# Lan Mouse

The bar and panel follow `lan-mouse cli input-state --watch` from the local
daemon (one snapshot per routing change); the poll interval (30 seconds by
default) is only a safety net, and nothing runs but a cheap unit check every
10 seconds while the service is inactive. Requires the input-state
IPC extension supplied by nixos-config. No SSH is used for status.

The snapshot separates enabled peers, live connections, acknowledged outgoing
capture, and incoming input. Incoming and outgoing can both be present when
multiple physical keyboards/mice are used; this is not a global cursor owner.
IPC failure clears previous routing data and displays unknown while the daemon
is running. A restarted widget recovers directly from a new snapshot.

The lockscreen return button appears only for confirmed incoming input and runs
`go_back_command` (default `~/.config/lan-mouse/go-back`). The nixos-config helper
restarts the local daemon; the sender releases capture when its connection dies.
The physical release shortcut remains available on the sending machine.

Peer Enable/Disable changes the local outgoing connection. Start/Stop controls
the local service unless `start_command`/`stop_command` overrides are configured.
`gui_command` overrides the GTK launch command. `show_label` and `icon_color`
control the outgoing indicator; `poll_interval` sets snapshot polling frequency.
