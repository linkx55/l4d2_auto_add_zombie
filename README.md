# l4d2_auto_add_zombie

> **Left 4 Dead 2 dedicated server plugin — dynamic zombie & horde scaling**
> 按幸存者人数动态调整小僵尸与尸潮数量，所有限制**在代码层强制生效**。

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![SourceMod](https://img.shields.io/badge/SourceMod-1.11%2B-orange.svg)](https://www.sourcemod.net/)
[![Version](https://img.shields.io/badge/version-1.8.2-green.svg)](#)

**[简体中文](cn/README.md)** | **[English](en/README.en.md)** | **[Credits / 来源与致谢](cn/CREDITS.md)**

---

## Download / 下载

| Build | Archive | Description |
|---|---|---|
| **简体中文** | [`l4d2_auto_add_zombie_cn_v1.8.2.zip`](l4d2_auto_add_zombie_cn_v1.8.2.zip) | 中文注释 + 中文聊天框文案 |
| **English** | [`l4d2_auto_add_zombie_en_v1.8.2.zip`](l4d2_auto_add_zombie_en_v1.8.2.zip) | English comments + English chat strings |

> Sample both archives are also attached to the
> [latest release](../../releases/latest) page.
> **Install only ONE of the two** — they register the same cvars.

---

## What it does / 它做什么

The vanilla Director spawns a **fixed** number of zombies regardless of lobby
size, so a full server feels empty. This plugin scales zombie counts with the
survivor count — but unlike a naive "write a bigger number into `server.cfg`"
approach, it solves three concrete traps:

| Trap | How this plugin solves it |
|---|---|
| A fixed value is wrong for someone | **Per-parameter ladders** — each cvar has its own base / step / min / max |
| `z_common_limit` raised but nothing happens | Works on the **wanderer density** layer, which is what actually decides population |
| Hordes arrive on an already-full map | **Horde pulse cap** — temporarily opens headroom right before the horde fires |
| Tuning blind | **Built-in tick + heartbeat logging** so you can prove what changed |

👉 Full details: **[中文](cn/README.md)** / **[English](en/README.en.md)**

---

## Repository layout / 仓库结构

```
.
├── cn/                      ← 简体中文构建 / Simplified Chinese build
│   ├── README.md
│   ├── CREDITS.md
│   ├── addons/sourcemod/{plugins,scripting}/
│   ├── cfg/sourcemod/
│   └── extras/
├── en/                      ← English build
│   ├── README.en.md
│   ├── CREDITS.md
│   ├── addons/sourcemod/{plugins,scripting}/
│   ├── cfg/sourcemod/
│   └── extras/
├── l4d2_auto_add_zombie_cn_v1.8.2.zip
├── l4d2_auto_add_zombie_en_v1.8.2.zip
├── LICENSE
└── .gitignore
```

**Why `addons/` sits inside each language folder**: copy `cn/addons` and
`cn/cfg` straight over your `left4dead2/` directory — no renaming needed.

**The two builds use identical file names** — `l4d2_auto_add_zombie.smx`,
`l4d2_auto_add_zombie.sp`, `l4d2_auto_add_zombie.cfg` — and identical cvars.
They differ only in the language of the comments and player-facing strings.
So install **only one** of them. Whichever you pick, the console command is
the same: `sm plugins reload l4d2_auto_add_zombie`.

**中文**：两个包的文件名完全一致（`l4d2_auto_add_zombie.smx` / `.sp` / `.cfg`），
cvar 名也一致，**区别只在注释与提示文案的语言**。**只装其中一个**即可，
控制台命令都是 `sm plugins reload l4d2_auto_add_zombie`。

---

## Credits / 来源与致谢

**This plugin is a derivative work.**

| | |
|---|---|
| **Original plugin** | `动态僵尸.` ("Dynamic Zombies") |
| **Original author** | **Tom.** |
| **Original version** | v1.0.1 |

The original author's design — the cvar naming, the calculation skeleton and
the config format — is preserved and kept backward compatible. Everything this
project adds is documented in [CREDITS.md](cn/CREDITS.md).

原作者的 4 个核心 cvar 名称、语义与默认值**均未改动**，原版 v1.0.1 的 cfg
可以直接沿用。完整署名与再分发要求见 [CREDITS.md](cn/CREDITS.md)。

---

## Requirements / 依赖

- **SourceMod 1.11+** (built and tested on 1.12.0.7220)
- **[left4dhooks](https://forums.alliedmods.net/showthread.php?t=323220)**

---

## License / 许可

**GNU General Public License v3** — see [LICENSE](LICENSE).

Derivative of Tom.'s original work, distributed under the same terms.
If you redistribute this project, **please keep the credits section.**
