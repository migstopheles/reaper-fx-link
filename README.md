# FX Link

[![Tests](https://github.com/migstopheles/reaper-fx-link/actions/workflows/tests.yml/badge.svg)](https://github.com/migstopheles/reaper-fx-link/actions/workflows/tests.yml)

A REAPER script that links instances of the same plugin. Use it to copy one instance's settings to
others, or keep them permanently in sync: change any linked instance and the rest follow.

It's made for things like double-tracked guitars panned hard left/right that should share one
sound, but works for any set of instances. Plugins aren't wrapped or modified, so you keep using
your normal FX chains.

- Works with VST, VST3, CLAP, JSFX and AU plugins
- Two-way sync: tweak *any* linked instance, including via automation or presets
- Optional sync of internal state, for plugins whose knobs aren't host parameters
- Per-group parameter exclusions (e.g. keep each side's pan or width)
- One-off "Copy to others", undoable
- Link groups are saved in the project

## Requirements

- REAPER 7
- [ReaImGui](https://github.com/cfillion/reaimgui) 0.10 or newer. Install it via ReaPack
  (**Extensions > ReaPack > Browse packages**, search "ReaImGui"), then restart REAPER.

## Install

### With ReaPack (recommended)

1. **Extensions > ReaPack > Import repositories...** and paste:
   ```
   https://github.com/migstopheles/reaper-fx-link/raw/main/index.xml
   ```
2. **Extensions > ReaPack > Browse packages**, find **FX Link** and install it.
3. The action list now has **Script: FX Link.lua**. Give it a shortcut or put it on a toolbar.
   The toolbar button lights up while it's running.

ReaPack will offer updates when new versions are released.

### Manually

Download this repository and copy `FX Link.lua`, `FX Link - Diagnostics.lua` and the `fxlink`
folder into a folder inside REAPER's `Scripts` folder (**Options > Show REAPER resource path**).
Then **Actions > Show action list > New action... > Load ReaScript...** and pick `FX Link.lua`.

## Use

1. Open a plugin's window and click **New group from focused FX**.
2. Open another instance of the same plugin and click **Add focused FX**, or pick one from
   **Add FX from project...**. **The newly added instance takes on the group's settings.**
3. With **Sync** on, any change to any linked instance is applied to all of them. That includes
   your tweaks, automation and preset changes.
4. **Copy to others** copies everything from one instance to the rest of the group, including
   internal state that isn't exposed as parameters (for VST/VST3/CLAP plugins). You can undo it.
   For one-off copies without live syncing, turn **Sync** off.
5. **Excluded parameters** are never synced or copied. Use this for settings you want to keep
   different per instance, such as a plugin's own pan or stereo width.

**Syncing only happens while the FX Link window is open.** You can dock it to keep it out of the way.

### Plugins whose knobs aren't parameters (e.g. Two Notes Genome)

Live sync watches a plugin's *automatable parameters*. Some plugins don't expose most of their
controls that way. Two Notes Genome, for example, only exposes in/out gain, gate, transpose, lane
settings and ten assignable automation slots (A1–A10). Its amp and pedal knobs live in its internal
state, so parameter sync can't see them.

For those, tick **Also sync internal state** on the group. Edits you make in the focused plugin
window are then copied (as complete plugin state) to the other instances about half a second after
you stop adjusting. Only the focused instance is watched, so changes can't bounce back and forth.
Reloading a plugin's state can cause a short glitch on the other instances, so the option is off by
default.

A glitch-free alternative for a handful of controls: assign them to the plugin's own automation
slots (Genome's A1–A10). They become parameters and sync live.

If you're not sure what a plugin exposes, run **FX Link - Diagnostics.lua** (close the FX Link window
first). It records which parameters change while you turn a knob and saves a report to
`FX-Link-diagnostics.txt` in the REAPER resource folder.

### Start FX Link with REAPER

In the action list, right-click **Script: FX Link.lua** > **Copy selected action command ID**. Then
create (or add to) `Scripts/__startup.lua` in the REAPER resource folder:

```lua
reaper.Main_OnCommand(reaper.NamedCommandLookup('_RS...paste the ID here...'), 0)
```

Running it as an action, rather than with `dofile`, keeps the toolbar state working and prevents a
second copy from starting if you run the action again.

### Things to know

- **Automate only one instance per parameter.** If two linked instances both have an envelope for
  the same parameter, they will fight.
- If the instances already differed when sync started, FX Link doesn't guess which one is right. It
  shows how many parameters differ; click **Copy to others** on the instance you want to keep.
- Live parameter sync covers *parameters*. Internal state that isn't a parameter, such as a loaded
  sample or some mode switches, is transferred by **Copy to others**, when an instance joins a group,
  or live with **Also sync internal state** (see above).
- Some plugins expose read-only values (meters, gain-reduction readouts) as parameters. FX Link
  skips them when REAPER reports them as non-automatable, but some REAPER versions (including
  7.29) can't report this. If a linked plugin has one, exclude it under **Excluded parameters**.
- Not supported yet: FX inside containers, input/monitoring FX, and take (item) FX.

## Development

```
FX Link.lua                 entry point: window + main loop (also holds the ReaPack metadata)
FX Link - Diagnostics.lua   records what REAPER sees while you turn a knob
fxlink/model.lua            link groups, saved in the project (project ext state)
fxlink/engine.lua           finds FX, two-way sync, internal-state sync, copy
fxlink/ui.lua               ReaImGui window
tests/                      engine/model tests against a mock REAPER API
scripts/make_index.py       generates the ReaPack index.xml for a release
```

```bash
scripts/test.sh      # runs the tests on Lua 5.4 via Node + wasmoon (no Lua install needed)
scripts/install.sh   # copies this checkout into REAPER's Scripts/FX Link; re-run the action to reload
```

`install.sh` works from WSL, Git Bash, macOS and Linux. Set `REAPER_RESOURCE_PATH` to target a
portable install.

### How sync works

Each tick (about 30 times per second) the engine reads the linked instances' parameters and compares
each one with that same instance's value from the previous tick. A difference means something
changed that instance, so the value is written to the others. Tracking history per instance means a
plugin snapping a value to its own steps isn't mistaken for a new change, so instances can't
ping-pong. The parameter you're currently touching is always synced immediately. Other parameters
(automation, presets) are scanned within a fixed budget, so plugins with thousands of parameters
stay cheap.

REAPER marks every scripted parameter write as "last touched", so after syncing, FX Link re-touches
the parameter you actually touched. That keeps actions like *create envelope for last touched
parameter* working.

### Releasing

1. Bump `@version` and update `@changelog` in the header of `FX Link.lua`. Commit and push.
2. Run `python3 scripts/make_index.py`. It adds the new version to `index.xml`, with download URLs
   and SHA-256 hashes pinned to the pushed commit, and keeps older versions.
3. Commit `index.xml` and push. ReaPack users get the update.

## License

[MIT](LICENSE)
