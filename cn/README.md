# l4d2_auto_add_zombie

> **L4D2 专用服务器 · 动态僵尸数量插件（含硬性上下限、尸潮脉动上限、tick 监控）**
> 按幸存者人数自动缩放普通小僵尸与尸潮数量，所有限制**在代码层强制生效**。

**简体中文版** | [English version](../en/README.en.md)

---

## 📜 来源与致谢（Credits）

本插件是**二次开发的衍生版本（derivative work）**。原始作品与作者如下：

| 项目 | 内容 |
|---|---|
| **原插件名称** | `动态僵尸.`（Dynamic Zombies） |
| **原作者** | **Tom.** |
| **原始版本** | v1.0.1 |
| **原始功能** | 读取真人玩家数量，按 `l4d2_ai_auto_add_zombie`（每多 1 人增加 N 只）**线性缩放** 4 个僵尸 cvar：`z_common_limit` / `z_mob_spawn_min_size` / `z_mob_spawn_max_size` / `z_mega_mob_size`，并统一夹在 `l4d2_ai_max_zombie` 之内 |

**在此基础之上**，由「弹尽粮绝」服务器运维团队完成了 v1.2.0 → v1.8.2 共 **60+ 次迭代**的改造。
所有改动均为**增量式**，未推翻原作者的任何设计：

- 分项独立步进阶梯（`_step` / `_min` / `_max`）
- 代码层硬性上下限（防止任何来源写出越界值）
- 尸潮脉动上限（Pulse Cap）
- 内置 tick / 帧时监控与日志取证

> ❗ **兼容性承诺**：原插件的 4 个核心 cvar 语义、计算骨架与配置格式**保持向后兼容**，
> 因此你原来那份 v1.0.1 的 cfg 可以直接沿用，无需迁移。
> 这正是我们对原作者设计的一种尊重 —— 不做破坏性重构。

**许可证**：GNU General Public License v3（GPLv3），与原插件及 SourceMod 生态惯例一致。
衍生版本同样以 GPLv3 发布，任何再分发都必须保留本致谢章节。

---

## 这个插件解决什么问题

L4D2 原版的僵尸数量是**固定的**：4 个人打和 8 个人打，地图上的僵尸一样多。
人多了，玩家就会觉得"地图太空、没压力"。

常见的做法是直接在 `server.cfg` 里写死一个更大的数值，但这有三个坑：

| 坑 | 现象 |
|---|---|
| **写死 = 4 人房过难、8 人房过易** | 一个值不可能同时满足两种人数 |
| **`z_common_limit` 抬了没用** | 实测"贴上限率"恒为 0% —— 引擎根本填不满它 |
| **尸潮撞上满员地图** | 引擎只要有 cap 就会顶满，尸潮来了一只都塞不进去 |

本插件针对这三点分别给出了方案。

---

## 核心特性

### ① 分项阶梯：每个参数独立缩放

原版 v1.0.1 用一个 `l4d2_ai_auto_add_zombie` 倍率同时作用于 4 个参数。
本版把每个参数**拆成独立的四段旋钮**：

```
每 1 名玩家：  值 = base + step × (人数 - 起始人数)
最终：         值 = clamp(值, _min, _max)
```

好处是**单独调某一个参数不会再连带影响其他参数** —— 这是原版做不到的。

### ② 硬性上下限（代码层强制）

所有写入引擎的数值都会先经过 `_min` / `_max` 夹取。
**这是"真正生效"的限制**，而不是把值写进 cfg 就祈祷引擎不覆盖它。

⚠️ 已知陷阱：任何 `l4d2_*_max` 如果低于该参数的阶梯最高值，
整条阶梯会被**静默夹平**（所有人数档位取到同一个值）—— 这是排查时最常踩的坑。

### ③ 尸潮脉动上限（Pulse Cap）

**问题**：静态上限会让稳态 == 上限（实测 82% 的时间贴顶）。
尸潮来的时候，地图早就塞满了，一只都挤不进去 —— 玩家感觉"尸潮不震撼"。

**方案**：在尸潮定时器归零**前约 1.5 秒**，把 `z_common_limit` 临时抬高一个"空位"；
尸潮灌完之后 6–8 秒再降回原值。这样地图平时保持宽松，尸潮来时才腾出空间。

⚠️ **hold 时长不要超过 10 秒**，否则就变成"常驻高上限"，失去脉动意义。

v1.8.1 起，空位量按人数缩放（`l4d2_pulse_extra_step` / `_max`），
修复了"8 人时脉动把上限顶到 224、峰值冲到 227 导致掉 TICK"的问题。

### ④ tick 监控 + 心跳日志（v1.8.2）

服务器会定期往 **游戏根目录** 的 `l4d2_zombie_watch.log` 写一行心跳，包含：

```
alive / cap / peak / spawned / SI / pulse 状态 / tick= / fps= / ft=
```

当实测 tick 低于 `l4d2_ai_tick_warn`（默认 55）时，额外写一条 `TICKWARN` 行，
并带上**当时**的存活数、上限、出生数、特感数、脉动状态、尸潮剩余秒 —— 
让你能把"掉拍"和"当时发生了什么"直接对齐。

⚠️ 空转服务器（0 人）`GetGameTickCount()` 不前进，会误报 0 tick。
代码里已用 `dtick > 0` + `players > 0` 双闸挡掉假告警。

### ⑤ 两条调参命令

| 命令 | 作用 |
|---|---|
| `sm_zombies` | 打印当前各 cvar 的**实际生效值**（含计算后的阶梯值）与引擎现值对比 |
| `sm_zstat` | 直接数出当前存活的小僵尸数量、特感数量，以及距下次自然尸潮还有多久 |

---

## 安装

### 依赖

- **SourceMod 1.11 或更高**（在 1.12.0.7220 上编译并测试通过）
- **[left4dhooks](https://forums.alliedmods.net/showthread.php?t=323220)** —— 用于读取尸潮倒计时与 flow 距离

### 安装步骤

1. 把 `addons/` 和 `cfg/` 两个文件夹**直接覆盖**到服务器的 `left4dead2/` 目录下。
2. 确认 `l4d2_auto_add_zombie.smx` 出现在 `addons/sourcemod/plugins/` 下。
3. 确认 `l4d2_auto_add_zombie.cfg` 出现在 `cfg/sourcemod/` 下。

```
left4dead2/
├── addons/sourcemod/
│   ├── plugins/l4d2_auto_add_zombie.smx
│   └── scripting/l4d2_auto_add_zombie.sp
└── cfg/sourcemod/
    └── l4d2_auto_add_zombie.cfg
```

### ⚠️ 必须重启

**更换 `.smx` 后必须重启服务器**，`sm plugins reload` 不足以让新的 cvar 注册生效。

### 手动编译（可选）

```bash
spcomp64.exe -i<include目录> \
  -o l4d2_auto_add_zombie.smx \
  l4d2_auto_add_zombie.sp
```

在 SourceMod **1.12.0.7220** 上编译，只会出现一个 `CreateDialog` 的
标准弃用警告（来自 `halflife.inc`，与本插件无关），**无任何错误**。

---

## 版本说明

仓库提供**中文版**和**英文版**两个包。**两个包里的文件名完全一样**，只是放在不同文件夹：

| | `cn/` 文件夹 | `en/` 文件夹 |
|---|---|---|
| 插件文件 | `l4d2_auto_add_zombie.smx` | `l4d2_auto_add_zombie.smx` |
| 源码 | `l4d2_auto_add_zombie.sp` | `l4d2_auto_add_zombie.sp` |
| 配置 | `l4d2_auto_add_zombie.cfg` | `l4d2_auto_add_zombie.cfg` |
| 聊天框文案 | `[僵尸数量] 幸存者 8 人 → ...` | `[Zombies] 8 survivors -> ...` |
| 注释语言 | 简体中文 | English |

> ⭐ **两版唯一的区别就是「文件夹名」和「注释 / 提示文案的语言」。**
> 文件名、cvar 名、代码逻辑完全一致 ⇒ 无论装哪一个，
> 控制台命令都是同一句：`sm plugins reload l4d2_auto_add_zombie`
> 两个包**只装其中一个**（同时装会重复注册 cvar）。

---

## 参数速查

### 总开关

| cvar | 默认 | 说明 |
|---|---|---|
| `ai_enabled_zombie` | `1` | 总开关（原插件遗留） |
| `ai_playercount_zombie` | `2` | 超过这个人数才启用动态模式（原插件遗留） |

### 每个参数的四个旋钮

以 `l4d2_common_limit` 为例：

| cvar | 说明 |
|---|---|
| `l4d2_common_limit` | 基础值（起始人数时） |
| `l4d2_common_limit_step` | 每多 1 人增加多少 |
| `l4d2_common_limit_min` | 下限（硬夹） |
| `l4d2_common_limit_max` | 上限（硬夹） |

### 尸潮脉动

| cvar | 默认 | 说明 |
|---|---|---|
| `l4d2_pulse_enable` | `1` | 脉动总开关 |
| `l4d2_pulse_extra` | `20` | 空位基础值（**不要写 0**，0 = 自动模式，会取到过大的值） |
| `l4d2_pulse_extra_step` | `5` | 每多 1 人增加的额外空位 |
| `l4d2_pulse_extra_max` | `40` | 空位硬上限 |
| `l4d2_pulse_lead` | `1.5` | 尸潮倒计时到这个秒数时抬升 |
| `l4d2_pulse_hold` | `8.0` | 抬升后维持几秒（**别超 10 秒**） |
| `l4d2_pulse_finale_bonus` | `60` | 终章额外空位 |
| `l4d2_pulse_cap_max` | `180` | 脉动后的绝对上限保护 |

### 日志

| cvar | 默认 | 说明 |
|---|---|---|
| `l4d2_ai_log_enable` | `1` | 心跳日志开关 |
| `l4d2_ai_log_interval` | `1.0` | 心跳间隔（秒） |
| `l4d2_ai_tick_warn` | `55` | 低于这个 tick 就写 TICKWARN |
| `l4d2_ai_max_zombie` | `256` | **全局绝对上限**，所有参数最终都夹在这里（原插件遗留） |

---

## 日志分析

`extras/tickstat.py` 可以解析心跳日志：

```bash
python tickstat.py <日志路径> [行数] [目标tick] [all|main|watch]
```

输出 5 块报告：tick 分布、alive 分桶、出生速率、脉动状态、TICKWARN 归因。

---

## ⚠️ 必读注意事项

1. **换 `.smx` 必须重启服务器**，不能只 reload。
2. **`l4d2_pulse_extra` 永远不要写 0** —— 0 表示"自动模式"，会取
   `max(尸潮上限, 警报上限)`，数值过大。
3. **任何 `_max` 低于阶梯最高值 → 整条阶梯被静默夹平**（最常见的事故）。
4. **`z_spawn_range` 写入无效**（引擎恒为 1500），想加视野要用 `z_acquire_far_range`。
5. **`z_mob_recharge_rate` 是唯一能抬"~60 软预算墙"的旋钮**，
   `z_common_limit` 抬了不会增加僵尸（贴顶率恒 0%）。
6. **调低 mega 规模时必须同时调低 `l4d2_mega_mob_size_min`**，
   否则 base 值会被 `_min` 夹回去。
7. **cfg 里写的值 ≠ 插件实算值** —— 一定要用 `sm_zombies` 或无头环境实测确认。
8. `nb_update_frequency` 单位是**秒**（官方默认 **0**，"默认 0.1"是流传的错误说法），
   它**不影响僵尸数量**，只影响 NextBot AI 更新频率。
9. 本插件的 cfg 会在 `server.cfg` **之后**执行，所以**本文件覆盖 server.cfg 的同名设置**。

---

## 配套工具（`extras/`）

| 文件 | 用途 |
|---|---|
| `tickstat.py` | 心跳日志分析（tick 分布 / alive 分桶 / 出生速率 / 脉动归因） |
| `perf_nextbot.cfg` | NextBot 性能三档预设（A/B/C），降低 AI 开销 |
| `perf_nextbot_off.cfg` | 撤销上面那份，恢复默认 |
| `pulse_tune.cfg` | 脉动参数快速调优（可热加载 exec） |
| `wandering_fix.cfg` | 修复"大地图游荡僵尸过少" |
| `wandering_fix_off.cfg` | 撤销上面那份 |

---

## 已知限制

- 依赖 `left4dhooks`，纯 SourceMod 环境无法工作。
- 无头服务器（0 人）无法验证尸潮相关逻辑 —— 引擎在没人时不跑帧。
- `tickstat.py` 中有一处**中文常量 `"连续"` 是有意保留的**，
  用于识别观察者插件的日志行，**翻译掉会导致过滤器失效**。

---

## 致谢

- 原插件 **`动态僵尸.` v1.0.1** 作者 —— **Tom.**
  （本项目的全部基础设计，包括 cvar 命名与计算骨架，均来自其作品）
- [SourceMod](https://www.sourcemod.net/) 与
  [left4dhooks](https://forums.alliedmods.net/showthread.php?t=323220) 项目及其贡献者
- 所有参与实测与反馈的「弹尽粮绝」服务器玩家

---

## 许可

**GNU General Public License v3**（见 [LICENSE](LICENSE)）—— 与 SourceMod 生态惯例一致。

基于 Tom. 的原作二次开发，衍生版本沿用同一许可。
**再分发时请保留本 README 的「来源与致谢」章节。**
