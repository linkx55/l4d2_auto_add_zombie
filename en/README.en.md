# l4d2_auto_add_zombie_en

> **Left 4 Dead 2 dedicated server · Dynamic zombie-count plugin**
> (hard clamps · horde pulse cap · built-in tick monitoring)
> Scales common infected and horde sizes with survivor count —
> every limit is **enforced in code**, not merely written to a cfg.

**English build** | [简体中文版](../cn/README.md)

---

## 📜 Origin & Credits

This plugin is a **derivative work**. The original project it is based on:

| | |
|---|---|
| **Original plugin** | `动态僵尸.` ("Dynamic Zombies") |
| **Original author** | **Tom.** |
| **Original version** | v1.0.1 |
| **Original design** | Reads the real-player count and **linearly scales** four zombie cvars by `l4d2_ai_auto_add_zombie` ("+N per extra player"): `z_common_limit` / `z_mob_spawn_min_size` / `z_mob_spawn_max_size` / `z_mega_mob_size`, all clamped to `l4d2_ai_max_zombie`. |

**On top of that**, the "Dan Jin Liang Jue" server team carried out
**v1.2.0 → v1.8.2, 60+ iterations** of rework. Every change is **additive**;
none of the original author's design was thrown away:

- Per-parameter step ladders (`_step` / `_min` / `_max`)
- Hard clamps enforced in code (no source can write an out-of-range value)
- Horde pulse cap (temporary headroom during alerts)
- Built-in tick / frametime monitoring and logging

> ❗ **Backward compatibility**: the four original cvars, the calculation
> skeleton and the config format remain **compatible**, so an existing
> v1.0.1 cfg keeps working with no migration. That is a deliberate choice —
> we did not break the original design just to refactor it.

**License**: GNU General Public License v3 (GPLv3), matching the original
plugin and the SourceMod ecosystem. Derivative versions ship under GPLv3 as
well, and **any redistribution must keep this credits section**.

---

## The problem this solves

In vanilla L4D2 the zombie count is **fixed** — a 4-player lobby and an
8-player lobby get exactly the same number of zombies on the map. With more
players, the map feels empty and pressure-free.

The common fix is to hard-code a bigger value in `server.cfg`, but that has
three traps:

| Trap | Symptom |
|---|---|
| **A fixed value is wrong for someone** | Too hard at 4 players, too easy at 8 — one number can't serve both |
| **Raising `z_common_limit` does nothing** | Measured "at-cap ratio" stays at 0% — the engine simply never fills it |
| **Hordes arrive on an already-full map** | The engine tops out at the cap, so a horde has no room to spawn into |

This plugin addresses all three.

---

## Features

### 1) Per-parameter ladders

The original v1.0.1 applied a single `l4d2_ai_auto_add_zombie` multiplier to
four parameters at once. This build splits each parameter into **its own four
knobs**:

```
per extra player:  value = base + step * (players - start_players)
finally:           value = clamp(value, _min, _max)
```

The benefit is that **tuning one parameter no longer drags the others along** —
something the original could not do.

### 2) Hard clamps enforced in code

Every value written to the engine passes through a `_min` / `_max` clamp.
These are **real limits**, not cfg values that the engine is free to ignore.

⚠️ Known trap: if any `l4d2_*_max` is lower than that parameter's highest
ladder value, **the whole ladder is silently flattened** (every player count
ends up with the same value). This is the single most common tuning mistake.

### 3) Horde pulse cap

**Problem**: with a static cap, steady state == cap (measured at-cap 82% of
the time). When a horde spawns, the map is already full and nothing can get in —
players report the horde "doesn't feel impactful".

**Solution**: about **1.5 s before** the mob timer hits zero, temporarily raise
`z_common_limit` by a "headroom" amount; drop it back 6–8 s after the horde
has drained. The map stays loose normally and opens up exactly when the horde
needs the room.

⚠️ **Never hold longer than 10 s**, or it degenerates into a permanently
higher cap and the pulse means nothing.

Since v1.8.1 the headroom scales with player count
(`l4d2_pulse_extra_step` / `_max`), fixing the case where 8 players pushed the
cap to 224, peaked at 227, and dropped ticks.

### 4) Tick monitoring + heartbeat log (v1.8.2)

The plugin periodically writes one heartbeat line to
`l4d2_zombie_watch.log` in the game root containing:

```
alive / cap / peak / spawned / SI / pulse state / tick= / fps= / ft=
```

When the measured tick rate falls below `l4d2_ai_tick_warn` (default 55), an
extra `TICKWARN` line is written with **the state at that moment**: alive
count, cap, spawn rate, special-infected count, pulse state and seconds until
the next horde — so you can line up "the tick drop" with "what was happening".

⚠️ On an idle server (0 players) `GetGameTickCount()` does not advance, which
would produce false 0-tick alarms. The code guards this with a
`dtick > 0` + `players > 0` double gate.

### 5) Two tuning commands

| Command | Purpose |
|---|---|
| `sm_zombies` | Prints the **actually effective** value of each cvar (post-ladder) side by side with the live engine value |
| `sm_zstat` | Counts the currently alive common infected and specials, plus seconds until the next natural horde |

---

## Installation

### Requirements

- **SourceMod 1.11 or newer** (compiled and tested on 1.12.0.7220)
- **[left4dhooks](https://forums.alliedmods.net/showthread.php?t=323220)** — used to read the mob countdown and flow distance

### Steps

1. Copy the `addons/` and `cfg/` folders **directly over** the server's
   `left4dead2/` directory.
2. Confirm `l4d2_auto_add_zombie.smx` landed in `addons/sourcemod/plugins/`.
3. Confirm `l4d2_auto_add_zombie.cfg` landed in `cfg/sourcemod/`.

```
left4dead2/
├── addons/sourcemod/
│   ├── plugins/l4d2_auto_add_zombie.smx
│   └── scripting/l4d2_auto_add_zombie.sp
└── cfg/sourcemod/
    └── l4d2_auto_add_zombie.cfg
```

### ⚠️ A restart is required

**Replacing the `.smx` requires a server restart.** `sm plugins reload` is not
enough for the new cvar registrations to take effect.

### Compiling yourself (optional)

```bash
spcomp64.exe -i<include dir> \
  -o l4d2_auto_add_zombie.smx \
  l4d2_auto_add_zombie.sp
```

Compiled on SourceMod **1.12.0.7220**; the only output is a single standard
`CreateDialog` deprecation warning from `halflife.inc` (unrelated to this
plugin). **Zero errors.**

---

## About the two builds

The repo ships a **Chinese** and an **English** archive. **The file names are
IDENTICAL** in both — only the containing folder differs:

| | `cn/` folder | `en/` folder |
|---|---|---|
| Plugin | `l4d2_auto_add_zombie.smx` | `l4d2_auto_add_zombie.smx` |
| Source | `l4d2_auto_add_zombie.sp` | `l4d2_auto_add_zombie.sp` |
| Config | `l4d2_auto_add_zombie.cfg` | `l4d2_auto_add_zombie.cfg` |
| Chat strings | `[僵尸数量] 幸存者 8 人 → ...` | `[Zombies] 8 survivors -> ...` |
| Comments | Simplified Chinese | English |

> * The ONLY differences are the folder name and the language of the comments
>   and player-facing strings.
>   File names, cvar names and logic are identical => whichever you install,
>   the console command is the same: `sm plugins reload l4d2_auto_add_zombie`
>   Install only ONE of the two — installing both double-registers the cvars.

---

## Cvar reference

### Master switches

| cvar | Default | Description |
|---|---|---|
| `ai_enabled_zombie` | `1` | Master on/off (from the original plugin) |
| `ai_playercount_zombie` | `2` | Dynamic mode only activates above this player count (original plugin) |

### The four knobs per parameter

Using `l4d2_common_limit` as the example:

| cvar | Description |
|---|---|
| `l4d2_common_limit` | Base value (at the starting player count) |
| `l4d2_common_limit_step` | Added per extra player |
| `l4d2_common_limit_min` | Lower bound (hard clamp) |
| `l4d2_common_limit_max` | Upper bound (hard clamp) |

### Horde pulse

| cvar | Default | Description |
|---|---|---|
| `l4d2_pulse_enable` | `1` | Master switch for the pulse |
| `l4d2_pulse_extra` | `20` | Base headroom (**never set to 0** — 0 means "auto", which picks a far larger value) |
| `l4d2_pulse_extra_step` | `5` | Extra headroom per additional player |
| `l4d2_pulse_extra_max` | `40` | Hard cap on headroom |
| `l4d2_pulse_lead` | `1.5` | Raise when the mob countdown reaches this many seconds |
| `l4d2_pulse_hold` | `8.0` | How long to hold (keep **under 10 s**) |
| `l4d2_pulse_finale_bonus` | `60` | Extra headroom on the finale |
| `l4d2_pulse_cap_max` | `180` | Absolute safety ceiling while pulsed |

### Logging

| cvar | Default | Description |
|---|---|---|
| `l4d2_ai_log_enable` | `1` | Heartbeat logging on/off |
| `l4d2_ai_log_interval` | `1.0` | Heartbeat interval (seconds) |
| `l4d2_ai_tick_warn` | `55` | Write a TICKWARN line below this tick rate |
| `l4d2_ai_max_zombie` | `256` | **Global absolute ceiling** — everything clamps here last (original plugin) |

---

## Log analysis

`extras/tickstat.py` parses the heartbeat log:

```bash
python tickstat.py <log path> [lines] [target tick] [all|main|watch]
```

It prints five report blocks: tick distribution, alive-count buckets, spawn
rate, pulse state and TICKWARN attribution.

---

## ⚠️ Must-read notes

1. **Replacing the `.smx` requires a server restart** — reload is not enough.
2. **Never set `l4d2_pulse_extra 0`** — 0 means "auto" and resolves to
   `max(horde cap, alert cap)`, which is far too large.
3. **Any `_max` below the ladder's highest value silently flattens the whole
   ladder** — the most common accident.
4. **Writes to `z_spawn_range` have no effect** (the engine pins it at 1500).
   Use `z_acquire_far_range` if you want longer sight range.
5. **`z_mob_recharge_rate` is the only knob that moves the ~60 soft budget
   wall.** Raising `z_common_limit` does not add zombies (at-cap ratio stays 0%).
6. **When lowering the mega horde size you must lower
   `l4d2_mega_mob_size_min` at the same time**, otherwise `_min` clamps the
   base value right back.
7. **The value in the cfg is not the value the plugin computes** — always
   confirm with `sm_zombies` or a headless test.
8. `nb_update_frequency` is measured in **seconds** (official default **0**;
   the widely repeated "default 0.1" is a myth). It does **not** affect zombie
   count, only NextBot AI update frequency.
9. This plugin's cfg runs **after** `server.cfg`, so it **overrides** any
   same-named setting there.

---

## Bundled extras (`extras/`)

| File | Purpose |
|---|---|
| `tickstat.py` | Heartbeat log analysis (tick distribution / alive buckets / spawn rate / pulse attribution) |
| `perf_nextbot.cfg` | Three NextBot performance presets (A/B/C) to cut AI overhead |
| `perf_nextbot_off.cfg` | Reverts the above |
| `pulse_tune.cfg` | Quick pulse-parameter tuning (hot-loadable via `exec`) |
| `wandering_fix.cfg` | Fixes "too few wanderers on large maps" |
| `wandering_fix_off.cfg` | Reverts the above |

---

## Known limitations

- Requires `left4dhooks`; it will not work on a plain SourceMod install.
- Horde behaviour cannot be verified on a headless (0-player) server — the
  engine does not run frames with nobody connected.
- `tickstat.py` contains **one intentionally preserved Chinese literal
  (`"连续"`)** used to recognise observer-plugin log lines. **Translating it
  would break the filter.**

---

## Credits

- **`动态僵尸.` v1.0.1 by Tom.** — the original author. Every foundational
  design in this project, including the cvar naming and the calculation
  skeleton, comes from that work.
- [SourceMod](https://www.sourcemod.net/) and
  [left4dhooks](https://forums.alliedmods.net/showthread.php?t=323220),
  and all their contributors.
- Every player on the "Dan Jin Liang Jue" server who tested and reported back.

---

## License

**GNU General Public License v3** (see [LICENSE](LICENSE)) — consistent with
the SourceMod ecosystem.

This is a derivative of Tom.'s original work and ships under the same license.
**Please keep this README's credits section when redistributing.**
