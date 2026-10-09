/**
 * l4d2_auto_add_zombie  v1.8.2
 * ==================================================================
 *  【来源与致谢】
 *
 *  本插件是基于以下作品二次开发的衍生版本（derivative work）：
 *
 *      原插件名称：动态僵尸.
 *      原作者    ：Tom.
 *      原版本    ：v1.0.1
 *      原始行为  ：读取真人玩家数量，按 l4d2_ai_auto_add_zombie（每多 1 人
 *                  增加 N 只）线性缩放 4 个僵尸 cvar：
 *                  z_common_limit / z_mob_spawn_min_size /
 *                  z_mob_spawn_max_size / z_mega_mob_size，
 *                  并统一夹在 l4d2_ai_max_zombie 之内。
 *      本版改造  ：分项独立步进阶梯（_step / _min / _max）、代码层硬性上下限、
 *                  尸潮脉动上限（pulse cap）、内置 tick / 帧时监控。
 *
 *  ❗ 原版 4 个核心 cvar 的名称、语义与配置格式保持兼容，
 *     原版 v1.0.1 的 cfg 可直接沿用，无需迁移。
 *
 *  许可证：GNU GPL v3（与原插件及 SourceMod 生态一致）
 *  本文件为「简体中文」版本，英文版见仓库内 en 文件夹。
 * ==================================================================
 *
 * 根据幸存者人数动态调整小僵尸数量，并带【真正生效的硬性上下限】。
 *
 * 本插件管理的 8 个引擎 cvar（已在 server.dll / cvarlist 里核对）：
 *   z_common_limit          【同时存活】的小僵尸上限（"we can have at once"）
 *   z_mob_spawn_min_size    【一次普通尸潮】最少刷几只
 *   z_mob_spawn_max_size    【一次普通尸潮】最多刷几只
 *   z_mega_mob_size         【警报 / 大尸潮】一次刷几只
 *   z_wandering_density     【游荡密度】—— 真正决定"地图空不空"的那个值
 *   z_background_limit      【后台小僵尸上限】—— 不追人那批的配额
 *   z_density_region_length 【密度区域长度】—— 密度按多大范围评估（治扎堆）
 *   z_spawn_safety_range    【刷新安全距离】—— 生成点离玩家多远（治扎堆）
 *
 * 每个参数都是四段式，写进引擎前一律经过代码层夹取：
 *     实算值 = base + （人数 - 起始人数）× step  →  clamp(实算值, _min, _max)
 * ⚠️ 任何 _max 低于该参数的阶梯最高值 ⇒ 整条阶梯被静默夹平（最常见的调参事故）。
 *
 * ------------------------------------------------------------------
 *  三条决定成败的机制（改数值前务必先读）
 * ------------------------------------------------------------------
 * ① 抬 z_common_limit 并不会增加僵尸。
 *    引擎一旦拿到 cap 就会把它顶满，实际存活数长期远低于上限
 *    （"贴顶率"在所有人数下都是 0%）—— 也就是说这个值根本填不满。
 *    真正决定人口的是游荡僵尸系统（wanderer），由 z_wandering_density /
 *    z_background_limit 支配；原版把这两个值写死在 server.cfg 里，不随人数变化。
 *    本插件把它们也纳入按人数缩放。
 *    ⚠️ 光改密度是空转的，server.cfg 必须先有这一行：
 *           sm_cvar director_always_allow_wanderers 1
 *       没有它，游荡僵尸永远不会被允许生成，密度填多大都一样。
 *
 * ② 静态上限会让尸潮"渗进来"而不是"灌进来"。
 *    地图平时就顶满上限 ⇒ 尸潮触发时没有落脚空间
 *    （mob 定时器重置那一刻，存活数 Δ=+0，一只都不多刷）。
 *    ⇒ 解法：在尸潮那一刻把 z_common_limit 临时打开，事后收回。
 *      见下方"尸潮脉动上限"模块。
 *
 * ③ 治"走廊空着、全挤在一个小屋子里"。
 *    扎堆的根因是"1 秒内一次性灌入"：同样一批僵尸，缓释到几秒生成会明显摊开。
 *    两个杠杆：(a) 把一次灌入的量拆小（z_mob_spawn_* 本插件已在管）；
 *              (b) 放大引擎评估密度的"区域长度 / 安全距离 / 搜索范围"，
 *                  逼导演去更远、更散的位置挑刷新点。
 * ------------------------------------------------------------------
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <left4dhooks>

#define PLUGIN_VERSION "1.8.2"
#define PARAM_COUNT    4
#define FPARAM_COUNT   2
#define SPREAD_BIN     500.0
#define SPREAD_MAXBIN  512
#define PULSE_INTERVAL 0.2      // 脉动检查间隔（秒）

enum
{
	P_COMMON = 0,   // 常规小僵尸：同时存活上限
	P_MOBMIN,       // 一次普通尸潮：最小数量
	P_MOBMAX,       // 一次普通尸潮：最大数量
	P_MEGA          // 警报 / 大尸潮：数量
};

// 浮点型参数（游荡密度类）
enum
{
	FP_DENSITY = 0, // z_wandering_density  —— 游荡僵尸密度（★真正的地图空旷度开关）
	FP_BGLIMIT      // z_background_limit —— 后台小僵尸上限（不追人那批）
};

// 散布参数（治扎堆）
// 这两个不按"基础值+步进"的整数量缩放，而是按人数在 [min,max] 之间插值。
enum
{
	SP_REGION = 0,  // z_density_region_length —— 密度评估区域长度（越大→挑点范围越广→越散）
	SP_SAFETY,      // z_spawn_safety_range    —— 刷新安全距离（越大→离玩家越远→不贴脸堆）
	SP_RANGE,       // z_spawn_range           —— 刷新搜索范围（越大→能挑更远的点）
	SP_COUNT
};

// ---- 全局开关类 ----
ConVar g_hCvEnable;      // plugin_enable
ConVar g_hCvHint;        // plugin_hint
ConVar g_hCvDynamic;     // ai_enabled_zombie
ConVar g_hCvThreshold;   // ai_playercount_zombie
ConVar g_hCvGlobalCap;   // l4d2_ai_max_zombie
ConVar g_hCvCountBots;   // l4d2_ai_count_bots
ConVar g_hCvInterval;    // l4d2_ai_apply_interval
ConVar g_hCvForceTrim;   // l4d2_ai_force_trim
ConVar g_hCvTestPlayers; // l4d2_ai_test_players
ConVar g_hCvLogEnable;   // l4d2_ai_log_enable
ConVar g_hCvLogInterval; // l4d2_ai_log_interval
ConVar g_hCvTickWarn;    // l4d2_ai_tick_warn  实测tick低于此值写一行 TICKWARN (0=关闭)

// ---- 尸潮脉动上限（把尸潮从 z_common_limit 里"独立"出来） ----
// 原理：引擎只要给了 cap 就会把它顶满，所以尸潮来袭时一张满员的地图
//       一只也塞不进去（实测：mob 定时器重置时 alive Δ=+0）。
//       本模块在尸潮逼近/触发的那一刻把 z_common_limit 临时抬高，
//       让尸潮有"落脚空间"，保持几秒后再放下。
//       ★ cap 只拦"新生成"，降回去不会瞬杀已存在的僵尸，只是停止补充。
ConVar g_hCvPulseEnable;   // l4d2_pulse_enable      总开关
ConVar g_hCvPulseMode;     // l4d2_pulse_mode        1=尸潮定时器驱动 2=锯齿波(无条件)
ConVar g_hCvPulseExtra;    // l4d2_pulse_extra       开口子加多少只 (0=自动)
ConVar g_hCvPulseExtraStep;// l4d2_pulse_extra_step  空位随人数递增: 每多一人 +N (0=不随人数变)
ConVar g_hCvPulseExtraMax; // l4d2_pulse_extra_max   空位硬上限 (0=不限, 由 cap_max 兜底)
ConVar g_hCvPulseLead;     // l4d2_pulse_lead        提前多少秒开口子
ConVar g_hCvPulseHold;     // l4d2_pulse_hold        触发后保持多少秒
ConVar g_hCvPulseOn;       // l4d2_pulse_on          mode2: 开口子时长
ConVar g_hCvPulseOff;      // l4d2_pulse_off         mode2: 关闭时长
ConVar g_hCvPulseCapMax;   // l4d2_pulse_cap_max     开口子后的绝对上限(保护 tick)
ConVar g_hCvPulseFinale;   // l4d2_pulse_finale_bonus 救援关额外再加多少
ConVar g_hCvPulseDebug;    // l4d2_pulse_debug       0=安静 1=写日志 2=+聊天提示

// ---- 每个参数的 base / step / min / max ----
ConVar g_hCvBase[PARAM_COUNT];
ConVar g_hCvStep[PARAM_COUNT];   // 0 = 固定不随人数变化
ConVar g_hCvMin[PARAM_COUNT];
ConVar g_hCvMax[PARAM_COUNT];

// ---- 浮点参数（游荡密度类）----
ConVar g_hCvFBase[FPARAM_COUNT];
ConVar g_hCvFStep[FPARAM_COUNT];  // 0.0 = 固定
ConVar g_hCvFMin[FPARAM_COUNT];
ConVar g_hCvFMax[FPARAM_COUNT];

// ---- 散布参数（按人数在 min..max 间插值）----
ConVar g_hCvSpreadMin[SP_COUNT];
ConVar g_hCvSpreadMax[SP_COUNT];
ConVar g_hCvSpreadLow;
ConVar g_hCvSpreadHigh;
ConVar g_hCvSpreadOff;

// ---- 对应的引擎 cvar ----
ConVar g_hEngine[PARAM_COUNT];
ConVar g_hEngineF[FPARAM_COUNT];
ConVar g_hEngineS[SP_COUNT];

char g_szEngine[PARAM_COUNT][32];
char g_szLabel[PARAM_COUNT][32];
char g_szEngineF[FPARAM_COUNT][32];
char g_szLabelF[FPARAM_COUNT][32];
char g_szEngineS[SP_COUNT][32];
char g_szLabelS[SP_COUNT][32];

Handle g_hTimer = null;
Handle g_hLogTimer = null;
int g_iLastCommon = -1;
int g_iPeakAlive = 0;

// ---- 脉动状态 ----
Handle g_hPulseTimer = null;
bool   g_bPulseOn = false;      // 当前是否处于"开口子"状态
int    g_iCapBase = 0;          // 正常上限
int    g_iCapPulse = 0;         // 开口子时的上限
int    g_iHeadroom = 0;         // 空位 = iCapPulse - iCapBase
float  g_fMobPrevLeft = -1.0;   // 上一拍的 mob 倒计时（用来检测重置）
// ★ 保持/手动窗口一律用"按拍递减"的计数量，**不用 GetGameTime()**。
//   原因：0 人在线时游戏时钟不前进，用 now < deadline 判断会让
//   口子开了之后永远收不回来（开了就再也不会 OFF）。
float  g_fHoldLeft = 0.0;       // 尸潮触发后剩余保持秒数（每拍 -= PULSE_INTERVAL）
float  g_fForceLeft = 0.0;      // sm_hordepulse 手动开口子剩余秒数
int    g_iPulseTicks = 0;       // 已经连续开口子多少拍（防呆用）
int    g_iPulseFires = 0;       // 本次统计开了几次口子
bool   g_bNatStartArea = false; // left4dhooks 是否有 L4D_IsAnySurvivorInStartArea
bool   g_bNatFinale = false;    // left4dhooks 是否有 救援关 相关 native

// ---- 心跳记录器用的计数器 ----
char g_szLogFile[64] = "l4d2_zombie_watch.log";
int g_iSpawnWindow = 0;    // 本周期新生成的小僵尸数
int g_iSpawnTotal  = 0;    // 本图累计生成数
int g_iSpawnPeakWin = 0;   // 单周期最大生成数（最能说明"一波多猛"）
int g_iRecCount = 0;       // 已写行数

public Plugin myinfo =
{
	name        = "L4D2 Auto Add Zombie (hard-clamped)",
	// 原作者 Tom. 保留在首位；后续改造版本由本服务器团队维护。
	author      = "Tom. (original: 动态僵尸. v1.0.1) | 弹尽粮绝 server team (v1.2.0-v1.8.2)",
	description = "按人数动态调整小僵尸与尸潮数量，并强制夹在硬性上下限内（基于 Tom. 的「动态僵尸.」二次开发）",
	version     = PLUGIN_VERSION,
	url         = ""
};

public void OnPluginStart()
{
	strcopy(g_szEngine[P_COMMON], sizeof(g_szEngine[]), "z_common_limit");
	strcopy(g_szEngine[P_MOBMIN], sizeof(g_szEngine[]), "z_mob_spawn_min_size");
	strcopy(g_szEngine[P_MOBMAX], sizeof(g_szEngine[]), "z_mob_spawn_max_size");
	strcopy(g_szEngine[P_MEGA],   sizeof(g_szEngine[]), "z_mega_mob_size");

	strcopy(g_szLabel[P_COMMON], sizeof(g_szLabel[]), "常规小僵尸上限");
	strcopy(g_szLabel[P_MOBMIN], sizeof(g_szLabel[]), "尸潮最小数量");
	strcopy(g_szLabel[P_MOBMAX], sizeof(g_szLabel[]), "尸潮最大数量");
	strcopy(g_szLabel[P_MEGA],   sizeof(g_szLabel[]), "警报大尸潮数量");

	// ---- 浮点参数（游荡密度类）----
	strcopy(g_szEngineF[FP_DENSITY], sizeof(g_szEngineF[]), "z_wandering_density");
	strcopy(g_szEngineF[FP_BGLIMIT], sizeof(g_szEngineF[]), "z_background_limit");

	strcopy(g_szLabelF[FP_DENSITY], sizeof(g_szLabelF[]), "游荡密度(地图空旷度)");
	strcopy(g_szLabelF[FP_BGLIMIT], sizeof(g_szLabelF[]), "后台小僵尸上限");

	// ---- 散布参数（治扎堆）----
	strcopy(g_szEngineS[SP_REGION], sizeof(g_szEngineS[]), "z_density_region_length");
	strcopy(g_szEngineS[SP_SAFETY], sizeof(g_szEngineS[]), "z_spawn_safety_range");
	strcopy(g_szEngineS[SP_RANGE],  sizeof(g_szEngineS[]), "z_spawn_range");

	strcopy(g_szLabelS[SP_REGION], sizeof(g_szLabelS[]), "密度区域长度(挑点范围)");
	strcopy(g_szLabelS[SP_SAFETY], sizeof(g_szLabelS[]), "刷新安全距离(离玩家)");
	strcopy(g_szLabelS[SP_RANGE],  sizeof(g_szLabelS[]), "刷新搜索范围");

	// ---------- 全局 ----------
	g_hCvEnable = CreateConVar("plugin_enable", "1",
		"1=启用插件, 0=关闭(关闭后不再改动任何引擎cvar)", FCVAR_NOTIFY);

	g_hCvHint = CreateConVar("plugin_hint", "1",
		"1=数值变化时在聊天框提示, 0=静默", FCVAR_NOTIFY);

	g_hCvDynamic = CreateConVar("ai_enabled_zombie", "1",
		"是否动态改变僵尸数量. 0=固定(四个参数全部只用基础值), 1=按人数动态", FCVAR_NOTIFY);

	g_hCvThreshold = CreateConVar("ai_playercount_zombie", "0",
		"幸存者人数超过这个值之后才开始按人数加成 (0 = 从 1 人起就按人数算)", FCVAR_NOTIFY, true, 0.0, true, 32.0);

	g_hCvGlobalCap = CreateConVar("l4d2_ai_max_zombie", "48",
		"【全局绝对天花板】四个参数无论怎么算都不会超过这个值, 0=不限制", FCVAR_NOTIFY, true, 0.0, true, 512.0);

	g_hCvCountBots = CreateConVar("l4d2_ai_count_bots", "1",
		"1=电脑人(bot)也算进人数, 0=只算真人", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_hCvInterval = CreateConVar("l4d2_ai_apply_interval", "1.5",
		"周期性校正间隔(秒), 0=关闭周期性校正(只在人数/配置变化时写入)", FCVAR_NOTIFY, true, 0.0, true, 60.0);

	g_hCvForceTrim = CreateConVar("l4d2_ai_force_trim", "0",
		"1=同时存活的小僵尸超过硬上限时强制删除多余的, 0=不做删除", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_hCvTestPlayers = CreateConVar("l4d2_ai_test_players", "0",
		"调试用: 手动指定人数来测试夹取结果, 0=使用真实人数", FCVAR_NOTIFY, true, 0.0, true, 32.0);

	// ---------- 心跳记录器 ----------
	g_hCvLogEnable = CreateConVar("l4d2_ai_log_enable", "1",
		"1=把战场数据定期写入游戏根目录的 l4d2_zombie_watch.log, 0=关闭", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_hCvLogInterval = CreateConVar("l4d2_ai_log_interval", "1.0",
		"心跳记录间隔(秒), 0=关闭记录. 1.0 秒能看清一波尸潮的生成速度", FCVAR_NOTIFY, true, 0.0, true, 60.0);

	// tick 健康告警阈值
	g_hCvTickWarn = CreateConVar("l4d2_ai_tick_warn", "55",
		"实测 tick 低于此值时额外写一行 TICKWARN(含当时 alive/生成量/脉动). 0=关闭告警", FCVAR_NOTIFY, true, 0.0, true, 200.0);

	// ---------- 尸潮脉动上限 ----------
	g_hCvPulseEnable = CreateConVar("l4d2_pulse_enable", "1",
		"1=启用【尸潮脉动上限】: 尸潮来临时临时抬高 z_common_limit 给它落脚空间, 0=关闭", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_hCvPulseMode = CreateConVar("l4d2_pulse_mode", "1",
		"1=尸潮定时器驱动(和导演的尸潮同步); 2=锯齿波(无条件周期开口子, 能覆盖地图脚本机关/救援关)", FCVAR_NOTIFY, true, 1.0, true, 2.0);
	g_hCvPulseExtra = CreateConVar("l4d2_pulse_extra", "0",
		"开口子时额外给多少只空位. 0=自动(取 尸潮上限 与 警报上限 的较大者)", FCVAR_NOTIFY, true, 0.0, true, 512.0);
	g_hCvPulseExtraStep = CreateConVar("l4d2_pulse_extra_step", "0",
		"空位随人数递增: 每多一个人 +N (0=固定不随人数变化)", FCVAR_NOTIFY, true, 0.0, true, 64.0);
	g_hCvPulseExtraMax = CreateConVar("l4d2_pulse_extra_max", "0",
		"空位的硬上限. 0=不限(由 l4d2_pulse_cap_max 兜底)", FCVAR_NOTIFY, true, 0.0, true, 512.0);
	g_hCvPulseLead = CreateConVar("l4d2_pulse_lead", "1.5",
		"mode1: 尸潮倒计时剩余多少秒时提前开口子", FCVAR_NOTIFY, true, 0.0, true, 30.0);
	g_hCvPulseHold = CreateConVar("l4d2_pulse_hold", "8.0",
		"mode1: 尸潮触发后继续保持口子多少秒", FCVAR_NOTIFY, true, 0.0, true, 60.0);
	g_hCvPulseOn = CreateConVar("l4d2_pulse_on", "8.0",
		"mode2: 一个周期里开多久口子", FCVAR_NOTIFY, true, 0.5, true, 120.0);
	g_hCvPulseOff = CreateConVar("l4d2_pulse_off", "14.0",
		"mode2: 一个周期里关多久口子", FCVAR_NOTIFY, true, 0.5, true, 300.0);
	g_hCvPulseCapMax = CreateConVar("l4d2_pulse_cap_max", "300",
		"开口子后的绝对上限(保护 tick). 注意: 它绕过 l4d2_ai_max_zombie 的钳制", FCVAR_NOTIFY, true, 0.0, true, 1024.0);
	g_hCvPulseFinale = CreateConVar("l4d2_pulse_finale_bonus", "60",
		"救援关/逃生阶段额外再加多少空位(救援关尸潮偏少时调大)", FCVAR_NOTIFY, true, 0.0, true, 512.0);
	g_hCvPulseDebug = CreateConVar("l4d2_pulse_debug", "1",
		"0=安静, 1=每次开口子/收口子写一行日志, 2=同时聊天框提示", FCVAR_NOTIFY, true, 0.0, true, 2.0);

	// ---------- 1. 常规小僵尸：同时存活上限 ----------
	g_hCvBase[P_COMMON] = CreateConVar("l4d2_common_limit", "0",
		"常规小僵尸基础上限(配合 _step 使用)", FCVAR_NOTIFY, true, 0.0, true, 512.0);
	g_hCvStep[P_COMMON] = CreateConVar("l4d2_common_limit_step", "5",
		"常规小僵尸上限: 每多一个人 +N (0=固定不随人数变化)", FCVAR_NOTIFY, true, 0.0, true, 32.0);
	g_hCvMin[P_COMMON] = CreateConVar("l4d2_common_limit_min", "24",
		"★硬下限: 常规小僵尸上限不会低于此值 (原版默认上限是 30)", FCVAR_NOTIFY, true, 0.0, true, 512.0);
	g_hCvMax[P_COMMON] = CreateConVar("l4d2_common_limit_max", "48",
		"★硬上限: 常规小僵尸上限不会高于此值", FCVAR_NOTIFY, true, 0.0, true, 512.0);

	// ---------- 2. 一次普通尸潮的最小数量（默认固定） ----------
	g_hCvBase[P_MOBMIN] = CreateConVar("l4d2_mob_spawn_min_size", "16",
		"一次尸潮最少刷几只(基础值, 原版默认 10)", FCVAR_NOTIFY, true, 0.0, true, 512.0);
	g_hCvStep[P_MOBMIN] = CreateConVar("l4d2_mob_spawn_min_size_step", "0",
		"尸潮最小数量: 每多一个人 +N (0=固定不随人数变化)", FCVAR_NOTIFY, true, 0.0, true, 32.0);
	g_hCvMin[P_MOBMIN] = CreateConVar("l4d2_mob_spawn_min_size_min", "12",
		"★硬下限", FCVAR_NOTIFY, true, 0.0, true, 512.0);
	g_hCvMax[P_MOBMIN] = CreateConVar("l4d2_mob_spawn_min_size_max", "20",
		"★硬上限", FCVAR_NOTIFY, true, 0.0, true, 512.0);

	// ---------- 3. 一次普通尸潮的最大数量（默认固定） ----------
	g_hCvBase[P_MOBMAX] = CreateConVar("l4d2_mob_spawn_max_size", "24",
		"一次尸潮最多刷几只(基础值, 原版默认 30)", FCVAR_NOTIFY, true, 0.0, true, 512.0);
	g_hCvStep[P_MOBMAX] = CreateConVar("l4d2_mob_spawn_max_size_step", "0",
		"尸潮最大数量: 每多一个人 +N (0=固定不随人数变化)", FCVAR_NOTIFY, true, 0.0, true, 32.0);
	g_hCvMin[P_MOBMAX] = CreateConVar("l4d2_mob_spawn_max_size_min", "16",
		"★硬下限", FCVAR_NOTIFY, true, 0.0, true, 512.0);
	g_hCvMax[P_MOBMAX] = CreateConVar("l4d2_mob_spawn_max_size_max", "32",
		"★硬上限", FCVAR_NOTIFY, true, 0.0, true, 512.0);

	// ---------- 4. 警报 / 大尸潮 ----------
	g_hCvBase[P_MEGA] = CreateConVar("l4d2_mega_mob_size", "0",
		"警报/大尸潮一次刷几只(基础值)", FCVAR_NOTIFY, true, 0.0, true, 512.0);
	g_hCvStep[P_MEGA] = CreateConVar("l4d2_mega_mob_size_step", "4",
		"警报大尸潮数量: 每多一个人 +N (0=固定不随人数变化)", FCVAR_NOTIFY, true, 0.0, true, 32.0);
	g_hCvMin[P_MEGA] = CreateConVar("l4d2_mega_mob_size_min", "16",
		"★硬下限", FCVAR_NOTIFY, true, 0.0, true, 512.0);
	g_hCvMax[P_MEGA] = CreateConVar("l4d2_mega_mob_size_max", "32",
		"★硬上限(故意低于存活上限，避免一波警报把闸门瞬间打满)", FCVAR_NOTIFY, true, 0.0, true, 512.0);

	// ---------- 5. ★【游荡密度】z_wandering_density ----------
	// "地图上散步、不追人的小僵尸"的密度系数。原版默认 0.03，几乎等于没有。
	// 它是浮点数，所以 _step 也允许是小数。
	// ★ base 默认 0.25（体感"闲逛僵尸够了"），之后再随人数递增 ——
	//   低人数不会比现状差，高人数明显更满。
	g_hCvFBase[FP_DENSITY] = CreateConVar("l4d2_wandering_density", "0.25",
		"游荡僵尸密度基础值(小于等于阈值人数时). 原版 0.03, 推荐 0.25", FCVAR_NOTIFY, true, 0.0, true, 5.0);
	g_hCvFStep[FP_DENSITY] = CreateConVar("l4d2_wandering_density_step", "0.04",
		"游荡密度: 每多一个人 +N (0=固定不随人数变化). 0.04 = 每人加 4%", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_hCvFMin[FP_DENSITY] = CreateConVar("l4d2_wandering_density_min", "0.03",
		"★硬下限(原版值)", FCVAR_NOTIFY, true, 0.0, true, 5.0);
	g_hCvFMax[FP_DENSITY] = CreateConVar("l4d2_wandering_density_max", "0.70",
		"★硬上限. 0.70 是留了余量的保守天花板，再高收益递减且吃 tick", FCVAR_NOTIFY, true, 0.0, true, 5.0);

	// ---------- 6. ★【后台小僵尸上限】z_background_limit ----------
	// "How many common infected are on the background map at once"
	// 后台 = 玩家还没走到/不在视野内的那部分地图。原版默认 20。
	g_hCvFBase[FP_BGLIMIT] = CreateConVar("l4d2_background_limit", "400",
		"后台地图同时存在的小僵尸上限基础值. 原版默认 20", FCVAR_NOTIFY, true, 0.0, true, 4096.0);
	g_hCvFStep[FP_BGLIMIT] = CreateConVar("l4d2_background_limit_step", "30",
		"后台上限: 每多一个人 +N (0=固定不随人数变化)", FCVAR_NOTIFY, true, 0.0, true, 4096.0);
	g_hCvFMin[FP_BGLIMIT] = CreateConVar("l4d2_background_limit_min", "20",
		"★硬下限(原版值)", FCVAR_NOTIFY, true, 0.0, true, 4096.0);
	g_hCvFMax[FP_BGLIMIT] = CreateConVar("l4d2_background_limit_max", "800",
		"★硬上限", FCVAR_NOTIFY, true, 0.0, true, 4096.0);

	// ---------- 7. ★【散布控制】治"走廊空着、全挤一个小屋" ----------
	// 这三个值都按人数在 [min(低人数) , max(高人数)] 之间线性插值。
	// 插值端点定义：<= l4d2_spread_low_players 用 min 值；
	//               >= l4d2_spread_high_players 用 max 值。
	// 中间线性过渡。人数越多 → 挑点范围越大、离玩家越远 → 自然摊开。
	g_hCvSpreadMin[SP_REGION] = CreateConVar("l4d2_spread_region_min", "1500",
		"低人数时的 密度区域长度 z_density_region_length (原版 1500)", FCVAR_NOTIFY, true, 100.0, true, 20000.0);
	g_hCvSpreadMax[SP_REGION] = CreateConVar("l4d2_spread_region_max", "3200",
		"★高人数时的 密度区域长度 —— 调大让导演在更大范围内挑刷新点，是治扎堆的主开关",
		FCVAR_NOTIFY, true, 100.0, true, 20000.0);

	g_hCvSpreadMin[SP_SAFETY] = CreateConVar("l4d2_spread_safety_min", "550",
		"低人数时的 刷新安全距离 z_spawn_safety_range (原版 550)", FCVAR_NOTIFY, true, 0.0, true, 10000.0);
	g_hCvSpreadMax[SP_SAFETY] = CreateConVar("l4d2_spread_safety_max", "900",
		"★高人数时的 刷新安全距离 —— 调大让僵尸生成点离玩家更远，不在脸上堆",
		FCVAR_NOTIFY, true, 0.0, true, 10000.0);

	g_hCvSpreadMin[SP_RANGE] = CreateConVar("l4d2_spread_range_min", "1500",
		"低人数时的 刷新搜索范围 z_spawn_range (原版 1500)", FCVAR_NOTIFY, true, 100.0, true, 20000.0);
	g_hCvSpreadMax[SP_RANGE] = CreateConVar("l4d2_spread_range_max", "2500",
		"★高人数时的 刷新搜索范围 —— 调大让刷新点可以选得更远",
		FCVAR_NOTIFY, true, 100.0, true, 20000.0);

	// 插值端点（人数）
	g_hCvSpreadLow  = CreateConVar("l4d2_spread_low_players", "4",
		"散布参数插值起点人数: <= 此人数用 _min 值", FCVAR_NOTIFY, true, 0.0, true, 32.0);
	g_hCvSpreadHigh = CreateConVar("l4d2_spread_high_players", "8",
		"散布参数插值终点人数: >= 此人数用 _max 值", FCVAR_NOTIFY, true, 0.0, true, 32.0);
	g_hCvSpreadOff  = CreateConVar("l4d2_spread_off", "0",
		"1 = 关闭散布控制(完全不动那三个引擎 cvar)", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	// 解析引擎 cvar
	for (int i = 0; i < PARAM_COUNT; i++)
	{
		g_hEngine[i] = FindConVar(g_szEngine[i]);
		if (g_hEngine[i] == null)
			LogError("[add_zombie] 找不到引擎 cvar \"%s\"，该项将被跳过", g_szEngine[i]);
	}
	for (int i = 0; i < FPARAM_COUNT; i++)
	{
		g_hEngineF[i] = FindConVar(g_szEngineF[i]);
		if (g_hEngineF[i] == null)
			LogError("[add_zombie] 找不到引擎 cvar \"%s\"，该项将被跳过", g_szEngineF[i]);
	}
	for (int i = 0; i < SP_COUNT; i++)
	{
		g_hEngineS[i] = FindConVar(g_szEngineS[i]);
		if (g_hEngineS[i] == null)
			LogError("[add_zombie] 找不到引擎 cvar \"%s\"，该项将被跳过", g_szEngineS[i]);
	}

	AutoExecConfig(true, "l4d2_auto_add_zombie");

	// 配置改动后立刻重算（改 cfg 无需重启）
	g_hCvEnable.AddChangeHook(OnCvarChanged);
	g_hCvDynamic.AddChangeHook(OnCvarChanged);
	g_hCvThreshold.AddChangeHook(OnCvarChanged);
	g_hCvGlobalCap.AddChangeHook(OnCvarChanged);
	g_hCvTestPlayers.AddChangeHook(OnCvarChanged);
	g_hCvInterval.AddChangeHook(OnIntervalChanged);
	g_hCvLogEnable.AddChangeHook(OnLogSwitchChanged);
	g_hCvLogInterval.AddChangeHook(OnLogSwitchChanged);
	for (int i = 0; i < PARAM_COUNT; i++)
	{
		g_hCvBase[i].AddChangeHook(OnCvarChanged);
		g_hCvStep[i].AddChangeHook(OnCvarChanged);
		g_hCvMin[i].AddChangeHook(OnCvarChanged);
		g_hCvMax[i].AddChangeHook(OnCvarChanged);
	}
	// 这些项也要能热改
	for (int i = 0; i < FPARAM_COUNT; i++)
	{
		g_hCvFBase[i].AddChangeHook(OnCvarChanged);
		g_hCvFStep[i].AddChangeHook(OnCvarChanged);
		g_hCvFMin[i].AddChangeHook(OnCvarChanged);
		g_hCvFMax[i].AddChangeHook(OnCvarChanged);
	}
	for (int i = 0; i < SP_COUNT; i++)
	{
		g_hCvSpreadMin[i].AddChangeHook(OnCvarChanged);
		g_hCvSpreadMax[i].AddChangeHook(OnCvarChanged);
	}
	g_hCvSpreadLow.AddChangeHook(OnCvarChanged);
	g_hCvSpreadHigh.AddChangeHook(OnCvarChanged);
	g_hCvSpreadOff.AddChangeHook(OnCvarChanged);

	// 脉动：开关变化要重建定时器，其余变化立刻重算一次
	g_hCvPulseEnable.AddChangeHook(OnPulseSwitchChanged);
	g_hCvPulseMode.AddChangeHook(OnPulseSwitchChanged);
	g_hCvPulseExtra.AddChangeHook(OnPulseCvarChanged);
	g_hCvPulseExtraStep.AddChangeHook(OnPulseCvarChanged);
	g_hCvPulseExtraMax.AddChangeHook(OnPulseCvarChanged);
	g_hCvPulseLead.AddChangeHook(OnPulseCvarChanged);
	g_hCvPulseHold.AddChangeHook(OnPulseCvarChanged);
	g_hCvPulseOn.AddChangeHook(OnPulseCvarChanged);
	g_hCvPulseOff.AddChangeHook(OnPulseCvarChanged);
	g_hCvPulseCapMax.AddChangeHook(OnPulseCvarChanged);
	g_hCvPulseFinale.AddChangeHook(OnPulseCvarChanged);

	HookEvent("player_team", Event_PlayerTeam, EventHookMode_PostNoCopy);

	RegAdminCmd("sm_zombies", Cmd_Zombies, ADMFLAG_GENERIC, "查看小僵尸/尸潮数量限制");
	RegAdminCmd("sm_zstat", Cmd_ZStat, ADMFLAG_GENERIC, "查看实际存活的小僵尸数量 / 尸潮倒计时");
	RegAdminCmd("sm_hordepulse", Cmd_HordePulse, ADMFLAG_GENERIC, "手动脉动上限: sm_hordepulse [秒] (0=取消)");

	// ★ 提前查好 left4dhooks 的 native 是否真的存在。
	//   头文件里有、运行时没有（装了旧版 left4dhooks）= 调用即报错，
	//   所以一律先问 GetFeatureStatus，再决定要不要调。
	g_bNatStartArea = (GetFeatureStatus(FeatureType_Native, "L4D_IsAnySurvivorInStartArea") == FeatureStatus_Available);
	g_bNatFinale = (GetFeatureStatus(FeatureType_Native, "L4D_IsMissionFinalMap") == FeatureStatus_Available)
	            && (GetFeatureStatus(FeatureType_Native, "L4D_IsFinaleEscapeInProgress") == FeatureStatus_Available);

	StartApplyTimer();
	StartLogTimer();
	StartPulseTimer();
	ApplyZombieSettings(false);

	LogHeartbeat("PLUGIN START", true);
}

/* ------------------------------------------------------------------ */
/*  尸潮脉动上限                                                 */
/*                                                                     */
/*  为什么需要它：                            */
/*    引擎只要拿到 cap 就会把它顶满（贴顶率约 82%）。                  */
/*    所以尸潮来时撞上的是一张满员地图 —— mob 定时器重置那一刻          */
/*    存活数 Δ=+0 —— 一只都没多刷。                    */
/*    ⇒ 静态 cap 永远给不出"落脚空间"，尸潮只能"渗进来"。                */
/*    ⇒ 唯一解：在尸潮那一刻把天花板临时打开。                           */
/*                                                                     */
/*  两种驱动方式：                                                       */
/*    mode 1（默认）: mob 倒计时 <= lead 或刚重置 → 开口子 hold 秒       */
/*                   优点是和导演的尸潮同步（有尸潮音效/节奏）            */
/*    mode 2        : 无条件锯齿波，与任何地图脚本无关                   */
/*                   优点是"地图机关"（恐慌事件/救援关）也一并覆盖        */
/*                                                                     */
/*  ⚠️ 本模块写 z_common_limit 时**故意绕过** l4d2_ai_max_zombie 的全局   */
/*     钳制（那个上限是为了防呆，脉动就是要突破它），改用                 */
/*     l4d2_pulse_cap_max 单独保护 tick。                                */
/* ------------------------------------------------------------------ */

void StartPulseTimer()
{
	if (g_hPulseTimer != null)
		return;
	if (!g_hCvPulseEnable.BoolValue)
		return;
	g_hPulseTimer = CreateTimer(PULSE_INTERVAL, Timer_Pulse, _, TIMER_REPEAT);
}

void RestartPulseTimer()
{
	if (g_hPulseTimer != null)
	{
		delete g_hPulseTimer;
		g_hPulseTimer = null;
	}
	// 重新计算一次，保证开关一改就立刻生效（哪怕定时器被关掉）
	ComputePulse();
	ApplyZombieSettings(false);
	StartPulseTimer();
}

public void OnPulseSwitchChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	RestartPulseTimer();
}

public void OnPulseCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	ComputePulse();
	ApplyZombieSettings(false);
}

public Action Timer_Pulse(Handle timer)
{
	ComputePulse();
	return Plugin_Continue;
}

// 空位 = 这一拍应该给尸潮留多少落脚空间
int PulseHeadroom(int extra)
{
	int hd = g_hCvPulseExtra.IntValue;
	if (hd <= 0)
	{
		int m1 = ComputeParam(P_MOBMAX, extra);
		int m2 = ComputeParam(P_MEGA, extra);
		hd = (m1 > m2) ? m1 : m2;
	}
	else
	{
		// 空位按人数缩放：base + 额外人数 × step，最后夹 _max
		//   extra = 人数 - ai_playercount_zombie（与其它参数同一套“额外人数”）
		hd += extra * g_hCvPulseExtraStep.IntValue;

		int hmax = g_hCvPulseExtraMax.IntValue;
		if (hmax > 0 && hd > hmax)
			hd = hmax;
	}

	// 救援关 / 逃生阶段额外加一点
	int fb = g_hCvPulseFinale.IntValue;
	if (fb > 0 && g_bNatFinale)
	{
		if (L4D_IsMissionFinalMap() || L4D_IsFinaleEscapeInProgress())
			hd += fb;
	}
	return hd;
}

void ComputePulse()
{
	// ⚠️ 绝不能在函数开头写 g_bPulseOn = false ——
	//    那样"状态变化检测"（want == g_bPulseOn）每拍都会成立，
	//    于是每 0.2 秒都会记一次 PULSE ON，日志会被刷屏。
	if (!g_hCvPulseEnable.BoolValue)
	{
		if (g_bPulseOn)
		{
			g_bPulseOn = false;
			g_iCapBase = 0;
			g_iCapPulse = 0;
			g_iHeadroom = 0;
			ApplyZombieSettings(false);
		}
		return;
	}

	int players = CountSurvivors();
	int extra = (g_hCvDynamic.BoolValue && players > g_hCvThreshold.IntValue)
		? players - g_hCvThreshold.IntValue : 0;

	// ★ 每拍先把两个"剩余秒数"往下走（按拍递减，不依赖游戏时钟）；
	//   必须在下面判断 want 之前执行，否则会多看一拍。
	if (g_fHoldLeft > 0.0)
	{
		g_fHoldLeft -= PULSE_INTERVAL;
		if (g_fHoldLeft < 0.0)
			g_fHoldLeft = 0.0;
	}
	if (g_fForceLeft > 0.0)
	{
		g_fForceLeft -= PULSE_INTERVAL;
		if (g_fForceLeft < 0.0)
			g_fForceLeft = 0.0;
	}

	g_iCapBase = ComputeParam(P_COMMON, extra);
	g_iHeadroom = PulseHeadroom(extra);

	int cap = g_iCapBase + g_iHeadroom;
	int cmax = g_hCvPulseCapMax.IntValue;
	if (cmax > 0 && cap > cmax)
		cap = cmax;
	if (cap < g_iCapBase)
		cap = g_iCapBase;
	g_iCapPulse = cap;

	float now = GetGameTime();
	int mode = g_hCvPulseMode.IntValue;
	bool want = false;

	if (mode == 1)
	{
		float left = -1.0;
		if (LibraryExists("left4dhooks"))
			left = L4D2_CTimerGetCountdownDuration(L4D2CT_MobSpawnTimer);

		if (left >= 0.0)
		{
			// 倒计时"回跳" = 定时器刚重置 = 导演刚刚刷了一波尸潮
			if (g_fMobPrevLeft >= 0.0 && left > g_fMobPrevLeft + 2.0)
				g_fHoldLeft = g_hCvPulseHold.FloatValue;
			g_fMobPrevLeft = left;
		}

		// ⚠️ 必须 left > 0.01：定时器没启动时返回 0.0，
		//    否则会被判定成"永远濒临触发"→ 口子永久开着。
		if (left > 0.01 && left <= g_hCvPulseLead.FloatValue)
			want = true;
		if (g_fHoldLeft > 0.0)
			want = true;
	}
	else if (mode == 2)
	{
		float on  = g_hCvPulseOn.FloatValue;
		float cyc = on + g_hCvPulseOff.FloatValue;
		if (cyc > 0.1)
		{
			float ph = now - cyc * float(RoundToFloor(now / cyc));
			want = (ph < on);
		}
	}

	// 手动命令优先（两种 mode 都吃）
	if (g_fForceLeft > 0.0)
		want = true;

	// ---- 防呆：连续开口子太久就强制收 ----
	// （mode1 靠计时器、mode2 靠周期，理论上都不会超；这里只是保险，
	//   避免任何意外让口子一直开着把世界塞满）
	float span = g_hCvPulseOn.FloatValue;
	if (g_hCvPulseHold.FloatValue > span)
		span = g_hCvPulseHold.FloatValue;
	if (g_fForceLeft > span)
		span = g_fForceLeft;
	int maxTicks = RoundToNearest((span + 20.0) / PULSE_INTERVAL);
	if (maxTicks < 25)
		maxTicks = 25;

	if (g_bPulseOn && want)
	{
		g_iPulseTicks++;
		if (g_iPulseTicks > maxTicks)
		{
			want = false;
			g_fHoldLeft = 0.0;
			g_fForceLeft = 0.0;
		}
	}
	else
	{
		g_iPulseTicks = 0;
	}

	// 出生点保护：别让尸潮在安全屋/起始区生成
	if (want && g_bNatStartArea && L4D_IsAnySurvivorInStartArea())
	{
		want = false;
		g_fHoldLeft = 0.0;
	}

	if (want == g_bPulseOn)
		return;

	g_bPulseOn = want;
	if (want)
		g_iPulseFires++;

	if (g_hCvPulseDebug.IntValue >= 1)
	{
		char stamp[32];
		FormatTime(stamp, sizeof(stamp), "%H:%M:%S");
		LogToFileEx(g_szLogFile,
			"===== PULSE %s | %s | mode=%d | cap %d -> %d (空位 %d, 已开 %d 次) =====",
			want ? "ON" : "OFF", stamp, mode,
			g_iCapBase, want ? g_iCapPulse : g_iCapBase, g_iHeadroom, g_iPulseFires);
	}

	if (g_hCvPulseDebug.IntValue >= 2)
	{
		PrintToChatAll("\x04[尸潮脉动]\x01 %s → 存活上限 \x03%d\x01 (基础 %d + 空位 %d)",
			want ? "开口子" : "收口子", want ? g_iCapPulse : g_iCapBase,
			g_iCapBase, g_iHeadroom);
	}

	ApplyZombieSettings(false);
}

public Action Cmd_HordePulse(int client, int args)
{
	char arg[16];
	float secs = g_hCvPulseHold.FloatValue;

	if (args >= 1)
	{
		GetCmdArg(1, arg, sizeof(arg));
		secs = StringToFloat(arg);
	}

	if (secs <= 0.0)
	{
		g_fForceLeft = 0.0;
		g_fHoldLeft = 0.0;
		g_bPulseOn = false;
		ReplyToCommand(client, "[尸潮脉动] 已取消");
		ApplyZombieSettings(false);
		return Plugin_Handled;
	}

	g_fForceLeft = secs;
	ComputePulse();
	ReplyToCommand(client, "[尸潮脉动] 开口子 %.1f 秒 → 存活上限 %d (基础 %d + 空位 %d)",
		secs, g_iCapPulse, g_iCapBase, g_iHeadroom);
	return Plugin_Handled;
}

/* ------------------------------------------------------------------ */
/*  心跳记录器                                                         */
/* ------------------------------------------------------------------ */
void StartLogTimer()
{
	if (g_hLogTimer != null)
		return;

	if (!g_hCvLogEnable.BoolValue)
		return;

	float iv = g_hCvLogInterval.FloatValue;
	if (iv <= 0.0)
		return;

	g_hLogTimer = CreateTimer(iv, Timer_Log, _, TIMER_REPEAT);
}

void RestartLogTimer()
{
	if (g_hLogTimer != null)
	{
		delete g_hLogTimer;
		g_hLogTimer = null;
	}
	StartLogTimer();
}

public void OnLogSwitchChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	RestartLogTimer();
}

public Action Timer_Log(Handle timer)
{
	LogHeartbeat("TICK", false);
	return Plugin_Continue;
}

// 精确统计小僵尸的"出生次数" —— 这是唯一能测出"一波刷了几只"的办法
public void OnEntityCreated(int entity, const char[] classname)
{
	if (entity <= 0)
		return;
	if (classname[0] != 'i' || !StrEqual(classname, "infected", false))
		return;

	g_iSpawnWindow++;
	g_iSpawnTotal++;
	if (g_iSpawnWindow > g_iSpawnPeakWin)
		g_iSpawnPeakWin = g_iSpawnWindow;
}

/* ------------------------------------------------------------------ */
/*  分布均匀度：把每只小僵尸的 flow 距离按 500 单位分箱                  */
/* ------------------------------------------------------------------ */
void ComputeSpread(int &binsOut, int &maxBinOut, int &spanOut)
{
	binsOut = -1;
	maxBinOut = -1;
	spanOut = -1;

	if (!LibraryExists("left4dhooks"))
		return;

	int binIdx[SPREAD_MAXBIN];
	int binCnt[SPREAD_MAXBIN];
	int nBin = 0;
	float fmin = 0.0, fmax = 0.0;
	bool first = true;

	int ent = -1;
	while ((ent = FindEntityByClassname(ent, "infected")) != -1)
	{
		float f = L4D_GetInfectedFlowDistance(ent);
		if (f < 0.0)
			continue;

		if (first)
		{
			fmin = f;
			fmax = f;
			first = false;
		}
		else
		{
			if (f < fmin) fmin = f;
			if (f > fmax) fmax = f;
		}

		int b = RoundToFloor(f / SPREAD_BIN);
		int idx = -1;
		for (int i = 0; i < nBin; i++)
		{
			if (binIdx[i] == b)
			{
				idx = i;
				break;
			}
		}
		if (idx == -1)
		{
			if (nBin < SPREAD_MAXBIN)
			{
				binIdx[nBin] = b;
				binCnt[nBin] = 1;
				nBin++;
			}
		}
		else
		{
			binCnt[idx]++;
		}
	}

	int mx = 0;
	for (int i = 0; i < nBin; i++)
	{
		if (binCnt[i] > mx)
			mx = binCnt[i];
	}

	binsOut = nBin;
	maxBinOut = mx;
	spanOut = RoundToNearest(fmax - fmin);
}

/* ------------------------------------------------------------------ */
/*  tick 采样                                                  */
/*  ⚠️ 0 玩家的空转服务器上 GetGameTickCount() 不前进、GetGameFrameTime()=0 */
/*     ⇒ 必须判 dtick > 0，否则会写出 -1 / 假的 0 tick 告警              */
/* ------------------------------------------------------------------ */
int   g_iTickPrevCount = 0;
float g_fTickPrevTime  = 0.0;
float g_fLastTickRate  = -1.0;   // 最近一次实测 tick（供 sm_zstat / 心跳日志用）
float g_fLastFtMs      = -1.0;   // 最近一次帧时(ms)

// 实测 tick = 两次采样之间的 Δtick数 / Δ引擎秒。
// 独立于日志开关 —— 周期校正定时器也会调它，所以 sm_zstat 随时有值。
void SampleTick()
{
	int   tickNow = GetGameTickCount();
	float engNow  = GetEngineTime();
	float ft      = GetGameFrameTime();

	float rate = -1.0;
	if (g_fTickPrevTime > 0.0 && engNow > g_fTickPrevTime && tickNow > g_iTickPrevCount)
		rate = float(tickNow - g_iTickPrevCount) / (engNow - g_fTickPrevTime);

	g_iTickPrevCount = tickNow;
	g_fTickPrevTime  = engNow;
	g_fLastTickRate  = rate;
	g_fLastFtMs      = (ft > 0.0001) ? ft * 1000.0 : -1.0;
}

void LogHeartbeat(const char[] tag, bool header)
{
	if (!g_hCvLogEnable.BoolValue)
		return;

	char stamp[32];
	FormatTime(stamp, sizeof(stamp), "%Y-%m-%d %H:%M:%S");

	if (header)
	{
		char mapname[64];
		GetCurrentMap(mapname, sizeof(mapname));
		LogToFileEx(g_szLogFile,
			"===== %s | %s | map=%s | v%s | log_interval=%.1fs =====",
			tag, stamp, mapname, PLUGIN_VERSION, g_hCvLogInterval.FloatValue);

		g_iSpawnWindow = 0;
		g_iSpawnTotal = 0;
		g_iSpawnPeakWin = 0;
		g_iRecCount = 0;
		return;
	}

	int players = CountSurvivors();
	int alive   = CountAliveCommons();
	int si      = CountSpecialInfected();
	int witch   = CountEntitiesOfClass("witch");
	int tank    = CountEntitiesOfClass("tank");

	// ---- 实测 tick（见 SampleTick）----
	SampleTick();
	float tickRate = g_fLastTickRate;
	float ftMs     = g_fLastFtMs;
	float fps      = (ftMs > 0.0) ? (1000.0 / ftMs) : -1.0;

	int cap  = (g_hEngine[P_COMMON] != null) ? g_hEngine[P_COMMON].IntValue : -1;
	int mmin = (g_hEngine[P_MOBMIN] != null) ? g_hEngine[P_MOBMIN].IntValue : -1;
	int mmax = (g_hEngine[P_MOBMAX] != null) ? g_hEngine[P_MOBMAX].IntValue : -1;
	int mega = (g_hEngine[P_MEGA]   != null) ? g_hEngine[P_MEGA].IntValue   : -1;

	// 游荡密度 / 后台上限 / 散布参数（写进日志，方便 A/B 对比）
	float dens = (g_hEngineF[FP_DENSITY] != null) ? g_hEngineF[FP_DENSITY].FloatValue : -1.0;
	float bg   = (g_hEngineF[FP_BGLIMIT] != null) ? g_hEngineF[FP_BGLIMIT].FloatValue : -1.0;
	int   sreg = (g_hEngineS[SP_REGION]  != null) ? g_hEngineS[SP_REGION].IntValue  : -1;
	int   ssaf = (g_hEngineS[SP_SAFETY]  != null) ? g_hEngineS[SP_SAFETY].IntValue  : -1;
	int   sran = (g_hEngineS[SP_RANGE]   != null) ? g_hEngineS[SP_RANGE].IntValue   : -1;

	float mobLeft = -1.0;
	if (LibraryExists("left4dhooks"))
		mobLeft = L4D2_CTimerGetCountdownDuration(L4D2CT_MobSpawnTimer);

	// 分布均匀度：bins=占了多少个 500 单位的格子, maxbin=最挤一格多少只
	int bins, maxbin, span;
	if (alive > 0)
		ComputeSpread(bins, maxbin, span);
	else
	{
		bins = 0;
		maxbin = 0;
		span = 0;
	}

	LogToFileEx(g_szLogFile,
		"%s,alive=%d,cap=%d,peak=%d,players=%d,si=%d,witch=%d,tank=%d,spawned=%d,total=%d,mob_left=%.0f,timer=%s,eng=%d/%d-%d/%d,pulse=%d,capw=%d,hroom=%d,pfires=%d,dens=%.3f,bg=%.0f,spread=%d/%d/%d,bins=%d,maxbin=%d,span=%d,tick=%.1f,fps=%.0f,ft=%.2f",
		stamp, alive, cap, g_iPeakAlive, players, si, witch, tank,
		g_iSpawnWindow, g_iSpawnTotal, mobLeft,
		g_hTimer != null ? "run" : "STOP",
		cap, mmin, mmax, mega,
		g_bPulseOn ? 1 : 0, g_bPulseOn ? g_iCapPulse : g_iCapBase, g_iHeadroom, g_iPulseFires,
		dens, bg, sreg, ssaf, sran,
		bins, maxbin, span,
		tickRate, fps, ftMs);

	// ---- tick 告警（把"掉 tick"和"当时多少僵尸"直接对上）----
	// 只在真的有活人/真掉时才写，避免空转服务器的假告警
	int warnAt = g_hCvTickWarn.IntValue;
	if (warnAt > 0 && tickRate > 0.0 && tickRate < float(warnAt) && players > 0)
	{
		LogToFileEx(g_szLogFile,
			"===== TICKWARN | %s | 实测 %.1f tick/s | 帧时 %.2f ms | 存活 %d | 上限 %d | 峰值 %d | 出生 %d | 特感 %d | 脉动 %s(%d->%d) | 尸潮剩余 %.0f 秒 =====",
			stamp, tickRate, ftMs, alive, cap, g_iPeakAlive,
			g_iSpawnWindow, si,
			g_bPulseOn ? "开" : "关", g_iCapBase, g_bPulseOn ? g_iCapPulse : g_iCapBase,
			mobLeft);
	}

	g_iSpawnWindow = 0;
	g_iRecCount++;
}

/* ------------------------------------------------------------------ */
/*  换图 / 配置：只重新应用数值，绝不在这些回调里碰定时器               */
/*  （旧版就是在这里 KillTimer 一个已失效的句柄，抛异常后 CreateTimer    */
/*    被跳过，导致周期性校正永久失效）                                  */
/* ------------------------------------------------------------------ */
public void OnMapStart()
{
	g_iPeakAlive = 0;
	// 换图重置脉动状态，避免带着上一张图的倒计时/保持期过来
	g_iPulseFires = 0;
	g_iPulseTicks = 0;
	g_fMobPrevLeft = -1.0;
	g_fHoldLeft = 0.0;
	g_fForceLeft = 0.0;
	g_bPulseOn = false;
	ApplyZombieSettings(false);
	LogHeartbeat("MAP START", true);
}

public void OnConfigsExecuted()
{
	ApplyZombieSettings(false);
}

public void OnPluginEnd()
{
	if (g_hTimer != null)
	{
		delete g_hTimer;
		g_hTimer = null;
	}
	if (g_hLogTimer != null)
	{
		delete g_hLogTimer;
		g_hLogTimer = null;
	}
	if (g_hPulseTimer != null)
	{
		delete g_hPulseTimer;
		g_hPulseTimer = null;
	}
}

void StartApplyTimer()
{
	if (g_hTimer != null)
		return;                     // 已经在跑，不要重复建

	float interval = g_hCvInterval.FloatValue;
	if (interval <= 0.0)
		return;

	// 注意：不带 TIMER_FLAG_NO_MAPCHANGE —— 要它跨图继续存活
	g_hTimer = CreateTimer(interval, Timer_Apply, _, TIMER_REPEAT);
}

void RestartApplyTimer()
{
	if (g_hTimer != null)
	{
		delete g_hTimer;
		g_hTimer = null;
	}
	StartApplyTimer();
}

public void OnIntervalChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	RestartApplyTimer();
	ApplyZombieSettings(true);
}

public void OnCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	ApplyZombieSettings(true);
}

public Action Timer_Apply(Handle timer)
{
	SampleTick();              // 顺手采一次 tick（与日志开关无关）
	ApplyZombieSettings(true);
	return Plugin_Continue;
}

public void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
	CreateTimer(0.5, Timer_DelayedApply, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_DelayedApply(Handle timer)
{
	ApplyZombieSettings(true);
	return Plugin_Stop;
}

public void OnClientDisconnect(int client)
{
	CreateTimer(0.5, Timer_DelayedApply, _, TIMER_FLAG_NO_MAPCHANGE);
}

/* ------------------------------------------------------------------ */
/*  统计                                                               */
/* ------------------------------------------------------------------ */
int CountSurvivors()
{
	int fake = g_hCvTestPlayers.IntValue;
	if (fake > 0)
		return fake;

	int n = 0;
	bool countBots = g_hCvCountBots.BoolValue;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i))
			continue;
		if (IsFakeClient(i) && !countBots)
			continue;
		if (GetClientTeam(i) != 2)   // 2 = 幸存者
			continue;
		n++;
	}
	return n;
}

int CountEntitiesOfClass(const char[] cls)
{
	int n = 0;
	int ent = -1;
	while ((ent = FindEntityByClassname(ent, cls)) != -1)
		n++;
	return n;
}

int CountAliveCommons()
{
	return CountEntitiesOfClass("infected");
}

int CountSpecialInfected()
{
	int n = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i))
			continue;
		if (GetClientTeam(i) == 3)   // 3 = 感染者
			n++;
	}
	return n;
}

/* ------------------------------------------------------------------ */
/*  核心：算一个参数的最终值                                            */
/* ------------------------------------------------------------------ */
int ComputeParam(int idx, int extra)
{
	int value = g_hCvBase[idx].IntValue + extra * g_hCvStep[idx].IntValue;

	int lo = g_hCvMin[idx].IntValue;
	int hi = g_hCvMax[idx].IntValue;
	if (lo > hi)
	{
		int tmp = lo;
		lo = hi;
		hi = tmp;
	}

	if (value < lo)
		value = lo;
	if (value > hi)
		value = hi;

	int globalCap = g_hCvGlobalCap.IntValue;
	if (globalCap > 0 && value > globalCap)
		value = globalCap;

	return value;
}

/* ------------------------------------------------------------------ */
/*  算一个浮点参数（游荡密度 / 后台上限）                        */
/*  公式与整数版一致： base + extra × step → 夹 [min,max]               */
/* ------------------------------------------------------------------ */
float ComputeParamF(int idx, int extra)
{
	float value = g_hCvFBase[idx].FloatValue
	            + float(extra) * g_hCvFStep[idx].FloatValue;

	float lo = g_hCvFMin[idx].FloatValue;
	float hi = g_hCvFMax[idx].FloatValue;
	if (lo > hi)
	{
		float tmp = lo;
		lo = hi;
		hi = tmp;
	}

	if (value < lo)
		value = lo;
	if (value > hi)
		value = hi;

	return value;
}

/* ------------------------------------------------------------------ */
/*  算一个散布参数                                           */
/*  按人数在 [ _min(低人数) , _max(高人数) ] 之间线性插值。             */
/*  例：low=4 high=8，玩家 6 人 → 取 50% 位置。                        */
/* ------------------------------------------------------------------ */
int ComputeParamS(int idx, int players)
{
	int lo = g_hCvSpreadMin[idx].IntValue;
	int hi = g_hCvSpreadMax[idx].IntValue;

	int pLow  = g_hCvSpreadLow.IntValue;
	int pHigh = g_hCvSpreadHigh.IntValue;

	if (pLow > pHigh)
	{
		int tmp = pLow;
		pLow = pHigh;
		pHigh = tmp;
	}

	// 人数不足 / 达到终点：直接取端点
	if (players <= pLow)
		return lo;
	if (players >= pHigh)
		return hi;

	// 中间线性插值
	float t = float(players - pLow) / float(pHigh - pLow);
	return RoundToNearest(float(lo) + t * float(hi - lo));
}

/* ------------------------------------------------------------------ */
/*  应用                                                               */
/* ------------------------------------------------------------------ */
void ApplyZombieSettings(bool announce)
{
	if (!g_hCvEnable.BoolValue)
		return;

	int players = CountSurvivors();
	int extra   = 0;
	if (g_hCvDynamic.BoolValue && players > g_hCvThreshold.IntValue)
		extra = players - g_hCvThreshold.IntValue;

	int values[PARAM_COUNT];
	for (int i = 0; i < PARAM_COUNT; i++)
		values[i] = ComputeParam(i, extra);

	// 尸潮“最少”不允许超过“最多”
	if (values[P_MOBMIN] > values[P_MOBMAX])
		values[P_MOBMIN] = values[P_MOBMAX];

	// ---- 游荡密度 / 后台上限（浮点）----
	float fvalues[FPARAM_COUNT];
	for (int i = 0; i < FPARAM_COUNT; i++)
		fvalues[i] = ComputeParamF(i, extra);

	// ---- 散布参数（按实际人数插值）----
	int svalues[SP_COUNT];
	bool doSpread = !g_hCvSpreadOff.BoolValue;
	if (doSpread)
	{
		for (int i = 0; i < SP_COUNT; i++)
			svalues[i] = ComputeParamS(i, players);
	}

	bool changed = false;
	for (int i = 0; i < PARAM_COUNT; i++)
	{
		if (g_hEngine[i] == null)
			continue;
		// 开着脉动时 z_common_limit 交给下面统一写，避免同一拍写两次来回跳
		if (i == P_COMMON && g_hCvPulseEnable.BoolValue)
			continue;
		if (g_hEngine[i].IntValue == values[i])
			continue;

		g_hEngine[i].SetInt(values[i]);
		changed = true;
	}

	// ---- 尸潮脉动：z_common_limit 的最终值 ----
	// ★ 这里故意用 g_iCapPulse（已经由 l4d2_pulse_cap_max 保护过），
	//   不走 ComputeParam 的全局天花板钳制 —— 脉动的意义就是突破那个静态上限。
	int effCap = values[P_COMMON];
	if (g_hCvPulseEnable.BoolValue && g_hEngine[P_COMMON] != null)
	{
		effCap = g_bPulseOn ? g_iCapPulse : g_iCapBase;
		if (effCap <= 0)
			effCap = values[P_COMMON];
		if (g_hEngine[P_COMMON].IntValue != effCap)
		{
			g_hEngine[P_COMMON].SetInt(effCap);
			changed = true;
		}
	}

	// 浮点参数（注意比较用 FloatValue + 微小容差，避免浮点抖动导致每 1.5 秒反复写）
	for (int i = 0; i < FPARAM_COUNT; i++)
	{
		if (g_hEngineF[i] == null)
			continue;

		float cur = g_hEngineF[i].FloatValue;
		float nv  = fvalues[i];
		if (FloatAbs(cur - nv) < 0.0005)
			continue;

		g_hEngineF[i].SetFloat(nv);
		changed = true;
	}

	// 散布参数（整数）
	// ★ l4d2_spread_off=1 时不写"插值结果"，而是写回 _min 值（原版值）。
	//   早期实现是"直接跳过不写"，但这会导致引擎永远停在放大后的值上，
	//   关掉开关也回不去 —— 排查问题时没法干净地退回原版。
	//   现在改成：关掉 = 主动复位到 _min（通常是原版值）。
	for (int i = 0; i < SP_COUNT; i++)
	{
		if (g_hEngineS[i] == null)
			continue;

		int target = doSpread ? svalues[i] : g_hCvSpreadMin[i].IntValue;
		if (g_hEngineS[i].IntValue == target)
			continue;

		g_hEngineS[i].SetInt(target);
		changed = true;
	}

	if (values[P_COMMON] == g_iLastCommon)
		changed = false;
	else
		g_iLastCommon = values[P_COMMON];

	// 峰值统计（供 sm_zstat 用）
	int alive = CountAliveCommons();
	if (alive > g_iPeakAlive)
		g_iPeakAlive = alive;

	// ⚠️ 用 effCap（= 脉动后的真实上限）而不是 values[P_COMMON]，
	//    否则开口子期间会被 force_trim 把刚灌进来的尸潮又删掉。
	if (g_hCvForceTrim.BoolValue && alive > effCap)
		TrimTo(effCap);

	if (announce && g_hCvHint.BoolValue && changed)
	{
		PrintToChatAll("\x04[僵尸数量]\x01 幸存者 \x03%d\x01 人 → 存活上限 \x03%d\x01, 尸潮 \x03%d-%d\x01, 警报 \x03%d\x01, 游荡密度 \x03%.2f",
			players, effCap, values[P_MOBMIN], values[P_MOBMAX], values[P_MEGA],
			fvalues[FP_DENSITY]);
	}
}

void TrimTo(int cap)
{
	int total = CountAliveCommons();
	while (total > cap)
	{
		int victim = FindEntityByClassname(-1, "infected");
		if (victim == -1 || !IsValidEntity(victim))
			break;
		RemoveEntity(victim);
		total--;
	}
}

/* ------------------------------------------------------------------ */
/*  sm_zombies —— 配置视角                                             */
/* ------------------------------------------------------------------ */
public Action Cmd_Zombies(int client, int args)
{
	if (!g_hCvEnable.BoolValue)
	{
		ReplyToCommand(client, "[僵尸数量] 插件已关闭 (plugin_enable 0)");
		return Plugin_Handled;
	}

	int players = CountSurvivors();
	int extra = (g_hCvDynamic.BoolValue && players > g_hCvThreshold.IntValue)
		? players - g_hCvThreshold.IntValue : 0;

	ReplyToCommand(client, "[僵尸数量] 幸存者 %d 人%s | 加成级数 +%d | 全局天花板 %d | 插件 v%s",
		players, g_hCvTestPlayers.IntValue > 0 ? "(测试模式)" : "",
		extra, g_hCvGlobalCap.IntValue, PLUGIN_VERSION);

	for (int i = 0; i < PARAM_COUNT; i++)
	{
		int step  = g_hCvStep[i].IntValue;
		int raw   = g_hCvBase[i].IntValue + extra * step;
		int final = ComputeParam(i, extra);
		if (i == P_MOBMIN && final > g_hCvMax[P_MOBMAX].IntValue)
			final = g_hCvMax[P_MOBMAX].IntValue;
		int engine = (g_hEngine[i] != null) ? g_hEngine[i].IntValue : -1;

		ReplyToCommand(client, "  [%s] %s (%s): 实算 %d <- 原始 %d, 区间 [%d, %d], 引擎现值 %d",
			g_szEngine[i], g_szLabel[i], step == 0 ? "固定" : "随人数",
			final, raw, g_hCvMin[i].IntValue, g_hCvMax[i].IntValue, engine);
	}

	// ---- 浮点参数 ----
	for (int i = 0; i < FPARAM_COUNT; i++)
	{
		float stepF  = g_hCvFStep[i].FloatValue;
		float rawF   = g_hCvFBase[i].FloatValue + float(extra) * stepF;
		float finalF = ComputeParamF(i, extra);
		float engineF = (g_hEngineF[i] != null) ? g_hEngineF[i].FloatValue : -1.0;

		ReplyToCommand(client, "  [%s] %s (%s): 实算 %.3f <- 原始 %.3f, 区间 [%.3f, %.3f], 引擎现值 %.3f",
			g_szEngineF[i], g_szLabelF[i], stepF == 0.0 ? "固定" : "随人数",
			finalF, rawF, g_hCvFMin[i].FloatValue, g_hCvFMax[i].FloatValue, engineF);
	}

	// ---- 散布参数 ----
	if (g_hCvSpreadOff.BoolValue)
	{
		ReplyToCommand(client, "  [散布控制] 已关闭 (l4d2_spread_off 1) —— 已复位到 _min 值（原版值）");
		for (int i = 0; i < SP_COUNT; i++)
		{
			int engineS = (g_hEngineS[i] != null) ? g_hEngineS[i].IntValue : -1;
			ReplyToCommand(client, "  [%s] %s: 复位目标 %d, 引擎现值 %d",
				g_szEngineS[i], g_szLabelS[i], g_hCvSpreadMin[i].IntValue, engineS);
		}
	}
	else
	{
		for (int i = 0; i < SP_COUNT; i++)
		{
			int sv = ComputeParamS(i, players);
			int engineS = (g_hEngineS[i] != null) ? g_hEngineS[i].IntValue : -1;
			ReplyToCommand(client, "  [%s] %s: 插值 %d (区间 %d~%d), 引擎现值 %d",
				g_szEngineS[i], g_szLabelS[i], sv,
				g_hCvSpreadMin[i].IntValue, g_hCvSpreadMax[i].IntValue, engineS);
		}
		ReplyToCommand(client, "   （插值端点：%d 人用 _min 值，%d 人用 _max 值，中间线性过渡）",
			g_hCvSpreadLow.IntValue, g_hCvSpreadHigh.IntValue);
	}

	return Plugin_Handled;
}

/* ------------------------------------------------------------------ */
/*  sm_zstat —— 实际战场视角（调参靠这个）                              */
/* ------------------------------------------------------------------ */
public Action Cmd_ZStat(int client, int args)
{
	if (!g_hCvEnable.BoolValue)
	{
		ReplyToCommand(client, "[僵尸统计] 插件已关闭 (plugin_enable 0)");
		return Plugin_Handled;
	}

	if (args >= 1)
	{
		char arg[16];
		GetCmdArg(1, arg, sizeof(arg));
		if (StrEqual(arg, "reset", false))
		{
			g_iPeakAlive = CountAliveCommons();
			ReplyToCommand(client, "[僵尸统计] 峰值已重置为 %d", g_iPeakAlive);
			return Plugin_Handled;
		}
	}

	int players = CountSurvivors();
	int commons = CountAliveCommons();
	int si      = CountSpecialInfected();
	int witch   = CountEntitiesOfClass("witch");
	int tank    = CountEntitiesOfClass("tank");
	int cap     = (g_hEngine[P_COMMON] != null) ? g_hEngine[P_COMMON].IntValue : -1;

	ReplyToCommand(client, "[僵尸统计] 幸存者 %d 人 | 同时存活小僵尸 \x03%d\x01 / 上限 %d | 峰值 %d",
		players, commons, cap, g_iPeakAlive);
	ReplyToCommand(client, "           特殊感染者 %d | Witch %d | Tank %d", si, witch, tank);

	if (LibraryExists("left4dhooks"))
	{
		float left = L4D2_CTimerGetCountdownDuration(L4D2CT_MobSpawnTimer);
		ReplyToCommand(client, "           距下次自然尸潮: %.0f 秒", left);
	}

	// 实测 tick / 帧时（服务器稳不稳就看这一行）
	{
		char tickBuf[96];
		char rateBuf[32];
		if (g_fLastTickRate > 0.0)
			Format(rateBuf, sizeof(rateBuf), "%.1f", g_fLastTickRate);
		else
			Format(rateBuf, sizeof(rateBuf), "采样中");

		if (g_fLastFtMs > 0.0)
		{
			Format(tickBuf, sizeof(tickBuf), "           实测 tick: \x03%s\x01 tick/s (目标 64) | 帧时 \x03%.2f\x01 ms | FPS ~%.0f",
				rateBuf, g_fLastFtMs, 1000.0 / g_fLastFtMs);
			ReplyToCommand(client, "%s", tickBuf);
		}
		else
			ReplyToCommand(client, "           实测 tick: \x03%s\x01 tick/s | 帧时 无数据(空转/暂停)", rateBuf);
	}

	// 尸潮脉动状态 —— 判断"尸潮有没有落脚空间"就看这一行
	if (g_hCvPulseEnable.BoolValue)
	{
		ReplyToCommand(client, "           尸潮脉动: \x03%s\x01 | mode %d | 基础上限 %d + 空位 %d = %d | 本次已开 \x03%d\x01 次",
			g_bPulseOn ? "★开口子中" : "待命", g_hCvPulseMode.IntValue,
			g_iCapBase, g_iHeadroom, g_iCapPulse, g_iPulseFires);
		if (!g_bPulseOn && cap > 0 && g_iCapBase > 0 && cap != g_iCapBase)
			ReplyToCommand(client, "                 ⚠ 引擎现值 %d ≠ 期望 %d —— 可能被地图脚本覆盖了", cap, g_iCapBase);
	}

	// 分布均匀度
	{
		int bins, maxbin, span;
		if (commons > 0)
			ComputeSpread(bins, maxbin, span);
		else
		{
			bins = 0;
			maxbin = 0;
			span = 0;
		}
		if (bins >= 0)
		{
			ReplyToCommand(client, "           分布: 占了 \x03%d\x01 个 500 单位的格子 | 最挤一格 \x03%d\x01 只 | 跨度 %d",
				bins, maxbin, span);
			ReplyToCommand(client, "                 （格子越多越散；最挤一格超过存活数的 1/4 就是扎堆了）");
		}
	}

	ReplyToCommand(client, "           引擎现值: common=%d mob=%d-%d mega=%d | 周期校正 %s",
		cap,
		g_hEngine[P_MOBMIN] != null ? g_hEngine[P_MOBMIN].IntValue : -1,
		g_hEngine[P_MOBMAX] != null ? g_hEngine[P_MOBMAX].IntValue : -1,
		g_hEngine[P_MEGA]   != null ? g_hEngine[P_MEGA].IntValue   : -1,
		g_hTimer != null ? "运行中" : "已停止");

	// 游荡密度 / 后台上限 / 散布 —— 这几个才是"地图空不空、散不散"的真开关
	{
		char szDens[48] = "-";
		char szBg[48]   = "-";
		if (g_hEngineF[FP_DENSITY] != null)
			Format(szDens, sizeof(szDens), "%.3f", g_hEngineF[FP_DENSITY].FloatValue);
		if (g_hEngineF[FP_BGLIMIT] != null)
			Format(szBg, sizeof(szBg), "%.0f", g_hEngineF[FP_BGLIMIT].FloatValue);

		if (g_hCvSpreadOff.BoolValue)
		{
			ReplyToCommand(client, "           游荡密度 %s | 后台上限 %s | 散布控制 已关闭",
				szDens, szBg);
		}
		else
		{
			ReplyToCommand(client, "           游荡密度 \x03%s\x01 | 后台上限 %s | 散布 \x03%d/%d/%d\x01 (区域/安全/搜索)",
				szDens, szBg,
				g_hEngineS[SP_REGION] != null ? g_hEngineS[SP_REGION].IntValue : -1,
				g_hEngineS[SP_SAFETY] != null ? g_hEngineS[SP_SAFETY].IntValue : -1,
				g_hEngineS[SP_RANGE]  != null ? g_hEngineS[SP_RANGE].IntValue  : -1);
		}
	}

	return Plugin_Handled;
}
