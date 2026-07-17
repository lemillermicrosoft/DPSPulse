# DPSPulse Plan

## Vision
Build a World of Warcraft addon that displays a realtime rolling DPS graph during combat, with clear current DPS readout and a short visible history window.

## Scope (MVP)
- Track outgoing damage events in combat.
- Compute rolling DPS over a configurable time window (default: 10s).
- Render a live x/y line graph of DPS over time.
- Show current DPS value prominently near the graph.
- Reset/segment data cleanly between fights.
- Provide simple slash commands for show/hide and window size.

## Technical Tasks
1. Bootstrap addon structure
- Create `DPSPulse.toc` and core Lua entry files.
- Define saved variables for settings (position, scale, windowSeconds).

2. Combat event ingestion
- Register for `COMBAT_LOG_EVENT_UNFILTERED` and combat state events.
- Capture player outgoing damage events only.
- Normalize event payload handling for TBC-compatible API.

3. DPS data model
- Maintain timestamped damage buckets (e.g., per 0.2s or 0.5s).
- Compute rolling sum over last N seconds.
- Produce sampled points for graph rendering.
- Handle sparse/no-damage periods smoothly.

4. Graph UI
- Create movable, lockable frame.
- Draw axes and line series (texture segments or lightweight polyline approach).
- Auto-scale Y axis with sensible min/max behavior.
- Show current DPS and optional peak in text.

5. Fight lifecycle
- Detect combat start/end.
- Start fresh series per fight while preserving optional summary.
- Add optional short fade/clear after leaving combat.

6. Settings and commands
- `/dpspulse` to toggle frame.
- `/dpspulse window <seconds>` to adjust rolling window.
- `/dpspulse reset` to clear current fight data.

7. Performance and safety
- Throttle redraw updates (e.g., 10-20 FPS max).
- Bound memory for point history.
- Guard against nil events and API edge cases.

8. QA and validation
- Test on target client version with target dummy and dungeon combat.
- Validate rolling window accuracy against known damage bursts.
- Ensure no errors on reload, zoning, and combat transitions.

## Post-MVP Ideas
- Overlay multiple lines (instant DPS vs rolling average).
- Color zones for low/medium/high DPS.
- Fight summary mini-panel (duration, avg DPS, peak DPS).
- Export/print session stats.

## Deliverables
- Functional addon folder loadable by WoW.
- Configurable rolling DPS graph with stable performance.
- Basic documentation in README.
