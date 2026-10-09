# Origin & Credits

This file is the **formal attribution notice** for this project. It preserves the
original author's copyright information as required by GPLv3.

---

## 1. The original work

| Item | Content |
|---|---|
| Plugin name | `动态僵尸.` ("Dynamic Zombies") |
| Author | **Tom.** |
| Version | v1.0.1 |
| Cvars | 8: `ai_enabled_zombie` `ai_playercount_zombie` `l4d2_ai_auto_add_zombie` `l4d2_ai_max_zombie` `l4d2_common_limit` `l4d2_mega_mob_size` `l4d2_mob_spawn_min_size` `l4d2_mob_spawn_max_size` |
| Logic | Reads the real-player count → linearly scales 4 zombie cvars by `l4d2_ai_auto_add_zombie` → clamps everything to `l4d2_ai_max_zombie` |
| Original license | Not separately stated; this project carries it forward under GPLv3, matching SourceMod ecosystem convention |

---

## 2. This derivative work

| Item | Content |
|---|---|
| Name | `l4d2_auto_add_zombie` (this package is the English build) |
| Current version | v1.8.2 |
| Revision span | v1.2.0 → v1.8.2 (60+ iterations) |
| Maintainer | Dan Jin Liang Jue server team |
| License | GNU GPL v3 |

### What this derivative adds

| # | Feature | Version |
|---|---|---|
| 1 | Per-parameter independent step ladders (`_step` / `_min` / `_max`) | v1.2.0 |
| 2 | Hard clamps enforced in code (applied before every engine write) | v1.2.0 |
| 3 | Periodic correction timer (the original wrote values only on specific events) | v1.3.0 |
| 4 | Fix for the `Invalid timer handle` exception on map change | v1.3.0 |
| 5 | `sm_zstat` command (live alive count / specials / horde countdown) | v1.3.0 |
| 6 | Heartbeat log recorder (incl. per-horde statistics) | v1.5.0 |
| 7 | Distribution-uniformity measurement (flow binning: bins / maxbin / span) | v1.6.0 |
| 8 | Wanderer density scaled by player count + spawn-spreading control | v1.7.0 |
| 9 | Horde pulse cap | v1.8.0 |
| 10 | Pulse headroom scaled by player count (fixes the 227 peak / tick drop at 8 players) | v1.8.1 |
| 11 | Tick / frametime monitoring + TICKWARN attribution logging | v1.8.2 |

> **Compatibility**: all of the above is additive. The original 8 cvars keep
> their names, semantics and defaults, so an existing v1.0.1 cfg works unchanged.

---

## 3. Third-party dependencies

| Item | Author / Source | License |
|---|---|---|
| [SourceMod](https://www.sourcemod.net/) | AlliedModders LLC | GPLv3 |
| [left4dhooks](https://forums.alliedmods.net/showthread.php?t=323220) | community-maintained | GPLv3 |

---

## 4. Redistribution requirements

Under GPLv3, any redistribution of this plugin (source or binary) must:

1. keep this `CREDITS.md` or an equivalent attribution notice;
2. state in the README or plugin description that it is derived from
   Tom.'s `动态僵尸. v1.0.1`;
3. not remove the original author **Tom.** from the `author` field of the
   `Plugin myinfo` block;
4. release modified sources under the same GPLv3 terms.

---

## 5. Recommended wording to reuse

If you describe this plugin elsewhere, you may use this sentence directly:

> This plugin is derived from **`动态僵尸. v1.0.1` by Tom.**,
> extended with per-parameter ladders, code-enforced hard clamps,
> a horde pulse cap and tick monitoring by the Dan Jin Liang Jue server team.
> Released under GPLv3.

> 本插件基于 **Tom.** 的 **`动态僵尸. v1.0.1`** 二次开发，
> 在其基础上由「弹尽粮绝」服务器团队扩展了分项阶梯、代码层硬性上下限、
> 尸潮脉动上限与 tick 监控等功能，以 GPLv3 许可开源。
