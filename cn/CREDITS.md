# 来源与致谢 / Credits

本文件是本项目的**正式署名声明**，依据 GPLv3 的要求保留原始作者的著作权信息。
This file is the **formal attribution notice** for this project. It preserves the
original author's copyright information as required by GPLv3.

---

## 一、原始作品 / The original work

| 项目 / Item | 内容 / Content |
|---|---|
| 插件名称 / Plugin | `动态僵尸.`（Dynamic Zombies） |
| 原作者 / Author | **Tom.** |
| 原始版本 / Version | v1.0.1 |
| 原始 cvar 数 / Cvars | 8 个：`ai_enabled_zombie` `ai_playercount_zombie` `l4d2_ai_auto_add_zombie` `l4d2_ai_max_zombie` `l4d2_common_limit` `l4d2_mega_mob_size` `l4d2_mob_spawn_min_size` `l4d2_mob_spawn_max_size` |
| 原始逻辑 / Logic | 读取真人玩家数量 → 按 `l4d2_ai_auto_add_zombie` 线性缩放 4 个僵尸 cvar → 统一夹在 `l4d2_ai_max_zombie` |
| 原始许可 / License | 未单独声明；本项目按 SourceMod 生态惯例以 GPLv3 承接 |

---

## 二、本衍生作品 / This derivative work

| 项目 / Item | 内容 / Content |
|---|---|
| 名称 / Name | `l4d2_auto_add_zombie`（本包为简体中文版） |
| 当前版本 / Version | v1.8.2 |
| 改造起止 / Revisions | v1.2.0 → v1.8.2（60+ 次迭代） |
| 维护方 / Maintainer | 「弹尽粮绝」服务器运维团队（Dan Jin Liang Jue server team） |
| 许可 / License | GNU GPL v3 |

### 相对原始作品的增量 / What this derivative adds

| # | 特性 | 版本 |
|---|---|---|
| 1 | 分项独立步进阶梯（`_step` / `_min` / `_max`，每个参数独立） | v1.2.0 |
| 2 | 代码层硬性上下限（clamp 在写入引擎前强制执行） | v1.2.0 |
| 3 | 周期校正定时器（原版只在特定事件写一次，本版持续校正） | v1.3.0 |
| 4 | 修复换图时 `Invalid timer handle` 异常 | v1.3.0 |
| 5 | `sm_zstat` 命令（实时数存活数 / 特感 / 尸潮倒计时） | v1.3.0 |
| 6 | 心跳日志记录器（含每波尸潮统计） | v1.5.0 |
| 7 | 分布均匀度测量（flow 分箱：bins / maxbin / span） | v1.6.0 |
| 8 | 游荡密度按人数缩放 + 分布散布控制 | v1.7.0 |
| 9 | 尸潮脉动上限（Pulse Cap） | v1.8.0 |
| 10 | 脉动空位按人数缩放（治 8 人房峰值 227 掉 TICK） | v1.8.1 |
| 11 | tick / 帧时监控 + TICKWARN 归因日志 | v1.8.2 |

> **兼容性**：以上全部为**增量式**改动。原始 8 个 cvar 的名称、语义、默认值
> **均未改动**，原版 v1.0.1 的 cfg 可以直接沿用。
> Compatibility: all changes are additive. The original 8 cvars keep their
> names, semantics and defaults; an existing v1.0.1 cfg works unchanged.

---

## 三、第三方依赖 / Third-party dependencies

| 项目 / Item | 作者·来源 / Author / Source | 许可 / License |
|---|---|---|
| [SourceMod](https://www.sourcemod.net/) | AlliedModders LLC | GPLv3 |
| [left4dhooks](https://forums.alliedmods.net/showthread.php?t=323220) | 社区维护 / community | GPLv3 |

---

## 四、再分发要求 / Redistribution requirements

依据 GPLv3，任何再分发本插件（源码或编译产物）时必须：

1. **保留**本 `CREDITS.md` 文件，或等价的署名声明；
2. 在 README 或插件描述中**注明**基于 Tom. 的 `动态僵尸. v1.0.1` 二次开发；
3. **不得**移除源码 `Plugin myinfo` 中 `author` 字段对原作者 **Tom.** 的署名；
4. 若对源码做了修改再发布，须以 GPLv3 同样条款开放源码。

Under GPLv3, any redistribution of this plugin (source or binary) must:
1. keep this `CREDITS.md` or an equivalent attribution notice;
2. state in the README or plugin description that it is derived from
   Tom.'s `动态僵尸. v1.0.1`;
3. not remove the original author **Tom.** from the `author` field of the
   `Plugin myinfo` block;
4. release modified sources under the same GPLv3 terms.

---

## 五、规范写法参考 / Recommended wording to reuse

如果你要在别处介绍这个插件，可以直接用下面这句话：

> 本插件基于 **Tom.** 的 **`动态僵尸. v1.0.1`** 二次开发，
> 在其基础上由「弹尽粮绝」服务器团队扩展了分项阶梯、代码层硬性上下限、
> 尸潮脉动上限与 tick 监控等功能，以 GPLv3 许可开源。

> This plugin is derived from **`动态僵尸. v1.0.1` by Tom.**,
> extended with per-parameter ladders, code-enforced hard clamps,
> a horde pulse cap and tick monitoring by the Dan Jin Liang Jue server team.
> Released under GPLv3.
