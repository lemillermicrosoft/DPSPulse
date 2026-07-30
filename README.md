# DPSPulse

DPSPulse is a lightweight World of Warcraft addon that shows a realtime rolling DPS graph and current DPS value during combat.

## Features
- Tracks outgoing player and pet damage from combat log events.
- Computes rolling DPS over a configurable window (default: 10s).
- **Dual-series graph:** rolling-window DPS (heat gradient) *and* full-combat session DPS (teal) plotted on the same axes, mimicking Details-style meter overlays. Session line stays live during combat and freezes on the last fight's total DPS when combat ends.
- **Second readout** shows the session DPS number alongside the rolling number.
- Draws a live graph with auto-scaled Y axis and a heat-gradient line (blue -> green -> yellow -> red) reflecting DPS intensity.
- Shows current DPS and peak DPS.
- Handles combat start/end and clears after leaving combat.

## Commands
- `/dpspulse` or `/dpspulse toggle` - Toggle frame visibility.
- `/dpspulse show` - Show frame.
- `/dpspulse hide` - Hide frame.
- `/dpspulse window <seconds>` - Set rolling window (2 to 60).
- `/dpspulse reset` - Reset current fight data.
- `/dpspulse lock` - Lock frame movement.
- `/dpspulse unlock` - Unlock frame movement.
- `/dpspulse scale <value>` - Set frame scale (0.5 to 2.0).
- `/dpspulse help` - Show command help.

## Install
1. Copy this folder to your WoW AddOns directory as `DPSPulse`.
2. Ensure files are directly under `DPSPulse/`:
   - `DPSPulse.toc`
   - `DPSPulse.lua`
3. Start WoW and enable DPSPulse on the character select AddOns screen.

## Notes
- The addon is tuned for TBC-era combat log data format and also supports clients with `CombatLogGetCurrentEventInfo`.
- Redraw is throttled to reduce CPU usage.
