/**
 * l4d2_auto_add_zombie  v1.8.2
 * ==================================================================
 *  ORIGIN & CREDITS
 *
 *  This plugin is a DERIVATIVE WORK based on the following:
 *
 *      Original plugin : 动态僵尸.  ("Dynamic Zombies")
 *      Original author : Tom.
 *      Original version: v1.0.1
 *      Original design : reads the real-player count and linearly scales
 *                        four zombie cvars by l4d2_ai_auto_add_zombie
 *                        ("+N per extra player"):
 *                        z_common_limit / z_mob_spawn_min_size /
 *                        z_mob_spawn_max_size / z_mega_mob_size,
 *                        all clamped to l4d2_ai_max_zombie.
 *      This build adds : per-parameter step ladders (base / step / min / max),
 *                        hard clamps enforced in code, a horde pulse cap,
 *                        and built-in tick / frametime monitoring.
 *
 *  !! The four original cvars, the calculation skeleton and the config format
 *     stay backward-compatible, so an existing v1.0.1 cfg still works.
 *
 *  License: GNU GPL v3 (same as the original and the SourceMod ecosystem)
 *  This file is the ENGLISH build; see the cn folder for Simplified Chinese.
 * ==================================================================
 *
 * Scales common infected counts with survivor count, with HARD clamps that are
 * actually enforced in code (not just cfg values the engine can ignore).
 *
 * The eight engine cvars this plugin manages
 * (all cross-checked against server.dll / cvarlist):
 *   z_common_limit          cap on SIMULTANEOUSLY ALIVE commons
 *   z_mob_spawn_min_size    minimum spawned per normal horde
 *   z_mob_spawn_max_size    maximum spawned per normal horde
 *   z_mega_mob_size         count spawned per alert / mega horde
 *   z_wandering_density     wanderer density -- the value that actually
 *                           decides whether the map feels empty
 *   z_background_limit      quota for the commons that are not chasing anyone
 *   z_density_region_length how large an area the engine evaluates for density
 *                           (anti-clumping)
 *   z_spawn_safety_range    minimum distance from players to a spawn point
 *                           (anti-clumping)
 *
 * Every parameter is a four-part ladder, and every value written to the engine
 * passes through a code-side clamp:
 *     computed = base + (players - start_players) * step
 *     final    = clamp(computed, _min, _max)
 * !! Any _max below that parameter's highest ladder value silently flattens the
 *    whole ladder -- the single most common tuning mistake.
 *
 * ------------------------------------------------------------------
 *  THREE MECHANISMS THAT DECIDE WHETHER THIS WORKS (read before tuning)
 * ------------------------------------------------------------------
 * 1) Raising z_common_limit does NOT add zombies.
 *    The engine tops out at the cap, yet the real alive count stays far below
 *    it -- the "at-cap ratio" is 0% at every player count, i.e. the cap is
 *    never filled. What actually decides population is the wanderer system,
 *    governed by z_wandering_density / z_background_limit. Vanilla hard-codes
 *    those two in server.cfg and never scales them with player count. This
 *    plugin brings them into the player-count scaling too.
 *    !! Changing density alone is a NO-OP. server.cfg must contain:
 *           sm_cvar director_always_allow_wanderers 1
 *       Without it, wanderers are never allowed to spawn and the density value
 *       is irrelevant.
 *
 * 2) A static cap makes hordes "seep in" instead of "pour in".
 *    The map sits at the cap all the time, so when a horde fires there is no
 *    room to land (at the moment the mob timer resets, alive delta = +0 --
 *    not a single extra common).
 *    => Fix: temporarily open z_common_limit right at the horde, then close it
 *       again. See the "horde pulse cap" module below.
 *
 * 3) Fixing "corridor empty, everyone crammed in one room".
 *    Clumping is caused by a one-second dump: the same batch of commons spreads
 *    out noticeably when released over several seconds instead.
 *    Two levers: (a) break a single dump into smaller pieces (the plugin
 *    already manages z_mob_spawn_*); (b) enlarge the engine's density region
 *    length / safety range / search range, forcing the Director to pick
 *    farther, more spread-out spawn points.
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
#define PULSE_INTERVAL 0.2      // pulse check interval (seconds)

enum
{
	P_COMMON = 0,   // regular commons: simultaneously alive cap
	P_MOBMIN,       // normal horde: minimum count
	P_MOBMAX,       // normal horde: maximum count
	P_MEGA          // alert / mega horde: count
};

// float parameters (wanderer-density family)
enum
{
	FP_DENSITY = 0, // z_wandering_density  -- wanderer density (the real empty-map switch)
	FP_BGLIMIT      // z_background_limit -- background common limit (the non-chasing batch)
};

// spread parameters (anti-clumping)
// These do not use the integer "base + step" scaling; instead they interpolate
// linearly between [min,max] by player count.
enum
{
	SP_REGION = 0,  // z_density_region_length -- density eval region length (larger -> wider pick range -> more spread)
	SP_SAFETY,      // z_spawn_safety_range    -- spawn safety range (larger -> farther from players -> no face-stacking)
	SP_RANGE,       // z_spawn_range           -- spawn search range (larger -> can pick farther points)
	SP_COUNT
}

// ---- master switches ----
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
ConVar g_hCvTickWarn;    // l4d2_ai_tick_warn  write a TICKWARN line when measured tick drops below this (0=off)

// ---- horde pulse cap (decouples hordes from z_common_limit) ----
// Rationale: the engine fills whatever cap it is given, so on a full map a
//             horde has no room at all (alive delta was +0 when the
//             mob timer reset). This module temporarily raises z_common_limit
//             the moment a horde approaches/fires, giving it room to land,
//             then lowers it again after a few seconds.
//             NOTE: the cap only blocks NEW spawns; lowering it does not kill
//             existing zombies, it just stops replenishment.
ConVar g_hCvPulseEnable;   // l4d2_pulse_enable      master switch
ConVar g_hCvPulseMode;     // l4d2_pulse_mode        1=horde-timer driven 2=sawtooth (unconditional)
ConVar g_hCvPulseExtra;    // l4d2_pulse_extra       how much headroom to open (0=auto)
ConVar g_hCvPulseExtraStep;// l4d2_pulse_extra_step  headroom scales with players: +N per extra player (0=no scaling)
ConVar g_hCvPulseExtraMax; // l4d2_pulse_extra_max   headroom hard ceiling (0=unlimited, cap_max is the backstop)
ConVar g_hCvPulseLead;     // l4d2_pulse_lead        open the headroom this many seconds in advance
ConVar g_hCvPulseHold;     // l4d2_pulse_hold        hold open this many seconds after firing
ConVar g_hCvPulseOn;       // l4d2_pulse_on          mode2: open duration
ConVar g_hCvPulseOff;      // l4d2_pulse_off         mode2: closed duration
ConVar g_hCvPulseCapMax;   // l4d2_pulse_cap_max     absolute cap after opening (tick protection)
ConVar g_hCvPulseFinale;   // l4d2_pulse_finale_bonus extra headroom on finale maps
ConVar g_hCvPulseDebug;    // l4d2_pulse_debug       0=quiet 1=log 2=also chat

// ---- per-parameter base / step / min / max ----
ConVar g_hCvBase[PARAM_COUNT];
ConVar g_hCvStep[PARAM_COUNT];   // 0 = fixed, does not scale with player count
ConVar g_hCvMin[PARAM_COUNT];
ConVar g_hCvMax[PARAM_COUNT];

// ---- float parameters (wanderer-density family) ----
ConVar g_hCvFBase[FPARAM_COUNT];
ConVar g_hCvFStep[FPARAM_COUNT];  // 0.0 = fixed
ConVar g_hCvFMin[FPARAM_COUNT];
ConVar g_hCvFMax[FPARAM_COUNT];

// ---- spread parameters (interpolate min..max by player count) ----
ConVar g_hCvSpreadMin[SP_COUNT];
ConVar g_hCvSpreadMax[SP_COUNT];
ConVar g_hCvSpreadLow;
ConVar g_hCvSpreadHigh;
ConVar g_hCvSpreadOff;

// ---- corresponding engine cvars ----
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

// ---- pulse state ----
Handle g_hPulseTimer = null;
bool   g_bPulseOn = false;      // currently in "headroom open" state
int    g_iCapBase = 0;          // normal cap
int    g_iCapPulse = 0;         // cap while headroom is open
int    g_iHeadroom = 0;         // headroom = iCapPulse - iCapBase
float  g_fMobPrevLeft = -1.0;   // previous frame's mob countdown (used to detect reset)
// NOTE: hold / manual windows use a frame-decremented counter on purpose, and
//       NEVER GetGameTime(). Reason: with 0 players connected the game clock
//       does not advance, so `now < deadline` never expires and the headroom
//       stays open forever (once opened, it never closes).
float  g_fHoldLeft = 0.0;       // seconds remaining to hold after a horde fires (decremented by PULSE_INTERVAL)
float  g_fForceLeft = 0.0;      // seconds remaining for a manual sm_hordepulse window
int    g_iPulseTicks = 0;       // consecutive frames the headroom has been open (safety)
int    g_iPulseFires = 0;       // how many times headroom was opened this session
bool   g_bNatStartArea = false; // whether left4dhooks provides L4D_IsAnySurvivorInStartArea
bool   g_bNatFinale = false;    // whether left4dhooks provides the finale natives

// ---- heartbeat logger counters ----
char g_szLogFile[64] = "l4d2_zombie_watch.log";
int g_iSpawnWindow = 0;    // commons spawned this period
int g_iSpawnTotal  = 0;    // cumulative spawned this map
int g_iSpawnPeakWin = 0;   // max spawned in a single period (best indicator of "how violent a wave is")
int g_iRecCount = 0;       // lines written so far

public Plugin myinfo =
{
	name        = "L4D2 Auto Add Zombie (hard-clamped)",
	// Original author Tom. kept first; later revisions maintained by this server team.
	author      = "Tom. (original: 动态僵尸. v1.0.1) | Dan Jin Liang Jue server team (v1.2.0-v1.8.2)",
	description = "Scales common infected and horde sizes with player count, hard-clamped in code (derived from Tom.'s 动态僵尸.)",
	version     = PLUGIN_VERSION,
	url         = ""
};

public void OnPluginStart()
{
	strcopy(g_szEngine[P_COMMON], sizeof(g_szEngine[]), "z_common_limit");
	strcopy(g_szEngine[P_MOBMIN], sizeof(g_szEngine[]), "z_mob_spawn_min_size");
	strcopy(g_szEngine[P_MOBMAX], sizeof(g_szEngine[]), "z_mob_spawn_max_size");
	strcopy(g_szEngine[P_MEGA],   sizeof(g_szEngine[]), "z_mega_mob_size");

	strcopy(g_szLabel[P_COMMON], sizeof(g_szLabel[]), "Regular common cap");
	strcopy(g_szLabel[P_MOBMIN], sizeof(g_szLabel[]), "Horde minimum");
	strcopy(g_szLabel[P_MOBMAX], sizeof(g_szLabel[]), "Horde maximum");
	strcopy(g_szLabel[P_MEGA],   sizeof(g_szLabel[]), "Alert mega horde");

	// ---- float parameters (wanderer-density family) ----
	strcopy(g_szEngineF[FP_DENSITY], sizeof(g_szEngineF[]), "z_wandering_density");
	strcopy(g_szEngineF[FP_BGLIMIT], sizeof(g_szEngineF[]), "z_background_limit");

	strcopy(g_szLabelF[FP_DENSITY], sizeof(g_szLabelF[]), "Wanderer density (map emptiness)");
	strcopy(g_szLabelF[FP_BGLIMIT], sizeof(g_szLabelF[]), "Background common limit");

	// ---- spread parameters (anti-clumping) ----
	strcopy(g_szEngineS[SP_REGION], sizeof(g_szEngineS[]), "z_density_region_length");
	strcopy(g_szEngineS[SP_SAFETY], sizeof(g_szEngineS[]), "z_spawn_safety_range");
	strcopy(g_szEngineS[SP_RANGE],  sizeof(g_szEngineS[]), "z_spawn_range");

	strcopy(g_szLabelS[SP_REGION], sizeof(g_szLabelS[]), "Density region length (pick range)");
	strcopy(g_szLabelS[SP_SAFETY], sizeof(g_szLabelS[]), "Spawn safety range (dist from players)");
	strcopy(g_szLabelS[SP_RANGE],  sizeof(g_szLabelS[]), "Spawn search range");

	// ---------- global ----------
	g_hCvEnable = CreateConVar("plugin_enable", "1",
		"1=enable plugin, 0=disable (changes no engine cvar)", FCVAR_NOTIFY);

	g_hCvHint = CreateConVar("plugin_hint", "1",
		"1=print a chat message when values change, 0=silent", FCVAR_NOTIFY);

	g_hCvDynamic = CreateConVar("ai_enabled_zombie", "1",
		"Whether to scale zombie counts dynamically. 0=all four params use base only, 1=scale by player count", FCVAR_NOTIFY);

	g_hCvThreshold = CreateConVar("ai_playercount_zombie", "0",
		"Player-count bonus starts above this many survivors (0 = scale from 1 player up)", FCVAR_NOTIFY, true, 0.0, true, 32.0);

	g_hCvGlobalCap = CreateConVar("l4d2_ai_max_zombie", "48",
		"[GLOBAL ABSOLUTE CEILING] no parameter may exceed this regardless of computation. 0=no limit", FCVAR_NOTIFY, true, 0.0, true, 512.0);

	g_hCvCountBots = CreateConVar("l4d2_ai_count_bots", "1",
		"1=count bots as players, 0=real players only", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_hCvInterval = CreateConVar("l4d2_ai_apply_interval", "1.5",
		"Periodic correction interval in seconds. 0=disable periodic correction (only write on player/config change)", FCVAR_NOTIFY, true, 0.0, true, 60.0);

	g_hCvForceTrim = CreateConVar("l4d2_ai_force_trim", "0",
		"1=force-delete live commons above the hard cap, 0=never delete", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_hCvTestPlayers = CreateConVar("l4d2_ai_test_players", "0",
		"Debug: force a player count to test clamping. 0=use real count", FCVAR_NOTIFY, true, 0.0, true, 32.0);

	// ---------- heartbeat logger ----------
	g_hCvLogEnable = CreateConVar("l4d2_ai_log_enable", "1",
		"1=periodically write battlefield data to l4d2_zombie_watch.log in the game root, 0=off", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_hCvLogInterval = CreateConVar("l4d2_ai_log_interval", "1.0",
		"Heartbeat interval in seconds. 0=disable logging. 1.0 lets you see a horde's spawn rate clearly", FCVAR_NOTIFY, true, 0.0, true, 60.0);

	// tick health warning threshold
	g_hCvTickWarn = CreateConVar("l4d2_ai_tick_warn", "55",
		"Write an extra TICKWARN line when measured tick drops below this (includes alive/spawned/pulse at that moment). 0=off", FCVAR_NOTIFY, true, 0.0, true, 200.0);

	// ---------- horde pulse cap ----------
	g_hCvPulseEnable = CreateConVar("l4d2_pulse_enable", "1",
		"1=enable horde pulse cap: temporarily raise z_common_limit when a horde lands so it has room to spawn. 0=off", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_hCvPulseMode = CreateConVar("l4d2_pulse_mode", "1",
		"1=horde-timer driven (synced with the Director's hordes); 2=sawtooth (unconditional periodic opening, also covers map-script events / finales)", FCVAR_NOTIFY, true, 1.0, true, 2.0);
	g_hCvPulseExtra = CreateConVar("l4d2_pulse_extra", "0",
		"Extra headroom to open. 0=auto (uses the larger of horde cap and alert cap)", FCVAR_NOTIFY, true, 0.0, true, 512.0);
	g_hCvPulseExtraStep = CreateConVar("l4d2_pulse_extra_step", "0",
		"Headroom scales with player count: +N per extra player (0=fixed, no scaling)", FCVAR_NOTIFY, true, 0.0, true, 64.0);
	g_hCvPulseExtraMax = CreateConVar("l4d2_pulse_extra_max", "0",
		"Headroom hard ceiling. 0=unlimited (l4d2_pulse_cap_max is the backstop)", FCVAR_NOTIFY, true, 0.0, true, 512.0);
	g_hCvPulseLead = CreateConVar("l4d2_pulse_lead", "1.5",
		"mode1: open the headroom this many seconds before the horde countdown reaches zero", FCVAR_NOTIFY, true, 0.0, true, 30.0);
	g_hCvPulseHold = CreateConVar("l4d2_pulse_hold", "8.0",
		"mode1: keep the headroom open this many seconds after the horde fires", FCVAR_NOTIFY, true, 0.0, true, 60.0);
	g_hCvPulseOn = CreateConVar("l4d2_pulse_on", "8.0",
		"mode2: how long to keep it open per cycle", FCVAR_NOTIFY, true, 0.5, true, 120.0);
	g_hCvPulseOff = CreateConVar("l4d2_pulse_off", "14.0",
		"mode2: how long to keep it closed per cycle", FCVAR_NOTIFY, true, 0.5, true, 300.0);
	g_hCvPulseCapMax = CreateConVar("l4d2_pulse_cap_max", "300",
		"Absolute cap after opening (tick protection). Note: this BYPASSES the l4d2_ai_max_zombie clamp", FCVAR_NOTIFY, true, 0.0, true, 1024.0);
	g_hCvPulseFinale = CreateConVar("l4d2_pulse_finale_bonus", "60",
		"Extra headroom on finale maps / escape phase (raise this if finale hordes feel too small)", FCVAR_NOTIFY, true, 0.0, true, 512.0);
	g_hCvPulseDebug = CreateConVar("l4d2_pulse_debug", "1",
		"0=quiet, 1=log every open/close, 2=also print to chat", FCVAR_NOTIFY, true, 0.0, true, 2.0);

	// ---------- 1. regular commons: simultaneously alive cap ----------
	g_hCvBase[P_COMMON] = CreateConVar("l4d2_common_limit", "0",
		"Regular common base cap (used together with _step)", FCVAR_NOTIFY, true, 0.0, true, 512.0);
	g_hCvStep[P_COMMON] = CreateConVar("l4d2_common_limit_step", "5",
		"Regular common cap: +N per extra player (0=fixed)", FCVAR_NOTIFY, true, 0.0, true, 32.0);
	g_hCvMin[P_COMMON] = CreateConVar("l4d2_common_limit_min", "24",
		"HARD FLOOR: the regular common cap never goes below this (vanilla cap is 30)", FCVAR_NOTIFY, true, 0.0, true, 512.0);
	g_hCvMax[P_COMMON] = CreateConVar("l4d2_common_limit_max", "48",
		"HARD CEILING: the regular common cap never goes above this", FCVAR_NOTIFY, true, 0.0, true, 512.0);

	// ---------- 2. normal horde minimum (fixed by default) ----------
	g_hCvBase[P_MOBMIN] = CreateConVar("l4d2_mob_spawn_min_size", "16",
		"Minimum commons per horde (base value; vanilla default 10)", FCVAR_NOTIFY, true, 0.0, true, 512.0);
	g_hCvStep[P_MOBMIN] = CreateConVar("l4d2_mob_spawn_min_size_step", "0",
		"Horde minimum: +N per extra player (0=fixed)", FCVAR_NOTIFY, true, 0.0, true, 32.0);
	g_hCvMin[P_MOBMIN] = CreateConVar("l4d2_mob_spawn_min_size_min", "12",
		"HARD FLOOR", FCVAR_NOTIFY, true, 0.0, true, 512.0);
	g_hCvMax[P_MOBMIN] = CreateConVar("l4d2_mob_spawn_min_size_max", "20",
		"HARD CEILING", FCVAR_NOTIFY, true, 0.0, true, 512.0);

	// ---------- 3. normal horde maximum (fixed by default) ----------
	g_hCvBase[P_MOBMAX] = CreateConVar("l4d2_mob_spawn_max_size", "24",
		"Maximum commons per horde (base value; vanilla default 30)", FCVAR_NOTIFY, true, 0.0, true, 512.0);
	g_hCvStep[P_MOBMAX] = CreateConVar("l4d2_mob_spawn_max_size_step", "0",
		"Horde maximum: +N per extra player (0=fixed)", FCVAR_NOTIFY, true, 0.0, true, 32.0);
	g_hCvMin[P_MOBMAX] = CreateConVar("l4d2_mob_spawn_max_size_min", "16",
		"HARD FLOOR", FCVAR_NOTIFY, true, 0.0, true, 512.0);
	g_hCvMax[P_MOBMAX] = CreateConVar("l4d2_mob_spawn_max_size_max", "32",
		"HARD CEILING", FCVAR_NOTIFY, true, 0.0, true, 512.0);

	// ---------- 4. alert / mega horde ----------
	g_hCvBase[P_MEGA] = CreateConVar("l4d2_mega_mob_size", "0",
		"Commons per alert/mega horde (base value)", FCVAR_NOTIFY, true, 0.0, true, 512.0);
	g_hCvStep[P_MEGA] = CreateConVar("l4d2_mega_mob_size_step", "4",
		"Alert mega horde size: +N per extra player (0=fixed)", FCVAR_NOTIFY, true, 0.0, true, 32.0);
	g_hCvMin[P_MEGA] = CreateConVar("l4d2_mega_mob_size_min", "16",
		"HARD FLOOR", FCVAR_NOTIFY, true, 0.0, true, 512.0);
	g_hCvMax[P_MEGA] = CreateConVar("l4d2_mega_mob_size_max", "32",
		"HARD CEILING (deliberately below the alive cap so one alert cannot instantly fill the gate)", FCVAR_NOTIFY, true, 0.0, true, 512.0);

	// ---------- 5. [wanderer density] z_wandering_density ----------
	// Density coefficient for the commons wandering around the map.
	// Vanilla default 0.03.
	// It is a float, so _step may be fractional.
	g_hCvFBase[FP_DENSITY] = CreateConVar("l4d2_wandering_density", "0.25",
		"Wanderer density base value (at or below the threshold player count). Vanilla 0.03", FCVAR_NOTIFY, true, 0.0, true, 5.0);
	g_hCvFStep[FP_DENSITY] = CreateConVar("l4d2_wandering_density_step", "0.04",
		"Wanderer density: +N per extra player (0=fixed). 0.04 = +4% per player", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_hCvFMin[FP_DENSITY] = CreateConVar("l4d2_wandering_density_min", "0.03",
		"HARD FLOOR (vanilla value)", FCVAR_NOTIFY, true, 0.0, true, 5.0);
	g_hCvFMax[FP_DENSITY] = CreateConVar("l4d2_wandering_density_max", "0.70",
		"HARD CEILING. 0.70 is a conservative margin; beyond that returns diminish and tick cost rises", FCVAR_NOTIFY, true, 0.0, true, 5.0);

	// ---------- 6. [background common limit] z_background_limit ----------
	// Engine description: "How many common infected are on the background map at
	// once". Background = the part of the map players have not reached / cannot
	// see. Vanilla default 20.
	g_hCvFBase[FP_BGLIMIT] = CreateConVar("l4d2_background_limit", "400",
		"Simultaneous commons allowed on the background map (base value). Vanilla default 20", FCVAR_NOTIFY, true, 0.0, true, 4096.0);
	g_hCvFStep[FP_BGLIMIT] = CreateConVar("l4d2_background_limit_step", "30",
		"Background limit: +N per extra player (0=fixed)", FCVAR_NOTIFY, true, 0.0, true, 4096.0);
	g_hCvFMin[FP_BGLIMIT] = CreateConVar("l4d2_background_limit_min", "20",
		"HARD FLOOR (vanilla value)", FCVAR_NOTIFY, true, 0.0, true, 4096.0);
	g_hCvFMax[FP_BGLIMIT] = CreateConVar("l4d2_background_limit_max", "800",
		"HARD CEILING", FCVAR_NOTIFY, true, 0.0, true, 4096.0);

	// ---------- 7. [spawn spreading] fixes "corridor empty, one room crammed" ----------
	// All three values interpolate linearly by player count between
	// [low-player value, high-player value].
	// Interpolation endpoints: <= l4d2_spread_low_players uses the min value;
	//                         >= l4d2_spread_high_players uses the max value;
	//                         linear in between.
	// More players -> wider pick range, farther from players -> naturally spreads.
	g_hCvSpreadMin[SP_REGION] = CreateConVar("l4d2_spread_region_min", "1500",
		"z_density_region_length at low player count (vanilla 1500)", FCVAR_NOTIFY, true, 100.0, true, 20000.0);
	g_hCvSpreadMax[SP_REGION] = CreateConVar("l4d2_spread_region_max", "3200",
		"z_density_region_length at high player count -- raise this to make the Director pick spawn points over a wider area. Main anti-clumping knob",
		FCVAR_NOTIFY, true, 100.0, true, 20000.0);

	g_hCvSpreadMin[SP_SAFETY] = CreateConVar("l4d2_spread_safety_min", "550",
		"z_spawn_safety_range at low player count (vanilla 550)", FCVAR_NOTIFY, true, 0.0, true, 10000.0);
	g_hCvSpreadMax[SP_SAFETY] = CreateConVar("l4d2_spread_safety_max", "900",
		"z_spawn_safety_range at high player count -- raise it so spawn points are farther from players instead of in their face",
		FCVAR_NOTIFY, true, 0.0, true, 10000.0);

	g_hCvSpreadMin[SP_RANGE] = CreateConVar("l4d2_spread_range_min", "1500",
		"z_spawn_range at low player count (vanilla 1500)", FCVAR_NOTIFY, true, 100.0, true, 20000.0);
	g_hCvSpreadMax[SP_RANGE] = CreateConVar("l4d2_spread_range_max", "2500",
		"z_spawn_range at high player count -- raise it so spawn points can be chosen farther away",
		FCVAR_NOTIFY, true, 100.0, true, 20000.0);

	// interpolation endpoints (player counts)
	g_hCvSpreadLow  = CreateConVar("l4d2_spread_low_players", "4",
		"Spread interpolation start: at or below this player count, the _min values are used", FCVAR_NOTIFY, true, 0.0, true, 32.0);
	g_hCvSpreadHigh = CreateConVar("l4d2_spread_high_players", "8",
		"Spread interpolation end: at or above this player count, the _max values are used", FCVAR_NOTIFY, true, 0.0, true, 32.0);
	g_hCvSpreadOff  = CreateConVar("l4d2_spread_off", "0",
		"1 = disable spread control (never touches those three engine cvars)", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	// resolve engine cvars
	for (int i = 0; i < PARAM_COUNT; i++)
	{
		g_hEngine[i] = FindConVar(g_szEngine[i]);
		if (g_hEngine[i] == null)
			LogError("[add_zombie] engine cvar \"%s\" not found, this entry will be skipped", g_szEngine[i]);
	}
	for (int i = 0; i < FPARAM_COUNT; i++)
	{
		g_hEngineF[i] = FindConVar(g_szEngineF[i]);
		if (g_hEngineF[i] == null)
			LogError("[add_zombie] engine cvar \"%s\" not found, this entry will be skipped", g_szEngineF[i]);
	}
	for (int i = 0; i < SP_COUNT; i++)
	{
		g_hEngineS[i] = FindConVar(g_szEngineS[i]);
		if (g_hEngineS[i] == null)
			LogError("[add_zombie] engine cvar \"%s\" not found, this entry will be skipped", g_szEngineS[i]);
	}

	AutoExecConfig(true, "l4d2_auto_add_zombie");

	// recompute immediately when config changes (no restart needed to change cfg)
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
	// these must also be hot-changeable
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

	// pulse: switch changes rebuild the timer, everything else recomputes once
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

	RegAdminCmd("sm_zombies", Cmd_Zombies, ADMFLAG_GENERIC, "Show common/horde count limits");
	RegAdminCmd("sm_zstat", Cmd_ZStat, ADMFLAG_GENERIC, "Show live common count / horde countdown");
	RegAdminCmd("sm_hordepulse", Cmd_HordePulse, ADMFLAG_GENERIC, "Manual pulse cap: sm_hordepulse [seconds] (0=cancel)");

	// Resolve left4dhooks natives up front.
	// A native present in the header but missing at runtime (old left4dhooks
	// build) errors on call, so always check GetFeatureStatus before calling.
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
/*  horde pulse cap                                             */
/*                                                                     */
/*  Why it is needed:           */
/*    The engine fills whatever cap it is given (~82% at-cap).  */
/*    So a horde arriving hits a full map -- the moment the mob timer   */
/*    resets, alive delta = +0, not one extra  */
/*    spawned.                                                          */
/*    => A static cap can never offer "room to land"; a horde can only  */
/*       seep in.                                                       */
/*    => The only fix is to open the ceiling temporarily at that moment.*/
/*                                                                     */
/*  Two drive modes:                                                    */
/*    mode 1 (default): mob countdown <= lead, or just reset -> open    */
/*                      for `hold` seconds. Advantage: synced with the */
/*                      Director's hordes (keeps horde audio/rhythm).   */
/*    mode 2        : unconditional sawtooth, independent of any map    */
/*                      script. Advantage: also covers map events       */
/*                      (panic events / finales).                       */
/*                                                                     */
/*  NOTE: when this module writes z_common_limit it DELIBERATELY        */
/*        bypasses the l4d2_ai_max_zombie global clamp (that ceiling is */
/*        a sanity guard, and the pulse exists to break it). Instead    */
/*        l4d2_pulse_cap_max protects tick on its own.                  */
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
	// recompute once so a switch change takes effect immediately
	// (even if the timer itself is disabled)
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

// headroom = how much room to leave for a horde this frame
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
		// headroom also scales with player count
		//   (base + extra players * step, then clamped to _max)
		//   extra = players - ai_playercount_zombie (same "extra players" as other params)
		hd += extra * g_hCvPulseExtraStep.IntValue;

		int hmax = g_hCvPulseExtraMax.IntValue;
		if (hmax > 0 && hd > hmax)
			hd = hmax;
	}

	// finale / escape phase gets a bit extra
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
	// NEVER clear g_bPulseOn at the top of this function --
	// that would make the "state changed" test (want == g_bPulseOn) true every
	// frame, producing a PULSE ON log line every 0.2 seconds
	// (the log gets flooded).
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

	// Decrement both "seconds remaining" counters first (frame-based, does not
	// rely on the game clock). This must happen before evaluating `want` below,
	// otherwise one extra frame is consumed.
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
			// A countdown "jump up" = the timer just reset = the Director just
			// fired a horde
			if (g_fMobPrevLeft >= 0.0 && left > g_fMobPrevLeft + 2.0)
				g_fHoldLeft = g_hCvPulseHold.FloatValue;
			g_fMobPrevLeft = left;
		}

		// MUST test left > 0.01: the timer returns 0.0 when not started,
		// otherwise this reads as "about to fire forever" and the headroom stays
		// open permanently.
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

	// manual command takes priority (works in both modes)
	if (g_fForceLeft > 0.0)
		want = true;

	// ---- safety: force-close if the headroom has been open too long ----
	// (mode1 is bounded by its timer and mode2 by its cycle, so this should
	//  never trigger; it is only insurance against an unexpected condition
	//  leaving the headroom open and flooding the world)
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

	// start-area protection: do not let a horde spawn in the safe room / start area
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
			"===== PULSE %s | %s | mode=%d | cap %d -> %d (headroom %d, opened %d times) =====",
			want ? "ON" : "OFF", stamp, mode,
			g_iCapBase, want ? g_iCapPulse : g_iCapBase, g_iHeadroom, g_iPulseFires);
	}

	if (g_hCvPulseDebug.IntValue >= 2)
	{
		PrintToChatAll("\x04[Pulse]\x01 %s -> alive cap \x03%d\x01 (base %d + headroom %d)",
			want ? "OPEN" : "CLOSE", want ? g_iCapPulse : g_iCapBase,
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
		ReplyToCommand(client, "[Pulse] cancelled");
		ApplyZombieSettings(false);
		return Plugin_Handled;
	}

	g_fForceLeft = secs;
	ComputePulse();
	ReplyToCommand(client, "[Pulse] opening headroom for %.1f sec -> alive cap %d (base %d + headroom %d)",
		secs, g_iCapPulse, g_iCapBase, g_iHeadroom);
	return Plugin_Handled;
}

/* ------------------------------------------------------------------ */
/*  Heartbeat logger                                                   */
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

// Accurately counts common infected "births" -- the only way to measure
// "how many spawned in one wave"
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
/*  Spawn distribution: bin every common's flow distance into 500 units */
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
/*  v1.8.2: tick sampling                                              */
/*  NOTE: on an idle server (0 players) GetGameTickCount() does not     */
/*        advance and GetGameFrameTime() = 0, so dtick > 0 must be      */
/*        checked or you will emit -1 / false 0-tick alarms.            */
/* ------------------------------------------------------------------ */
int   g_iTickPrevCount = 0;
float g_fTickPrevTime  = 0.0;
float g_fLastTickRate  = -1.0;   // most recent measured tick (used by sm_zstat / heartbeat log)
float g_fLastFtMs      = -1.0;   // most recent frame time (ms)

// Measured tick = delta ticks between two samples / delta engine seconds.
// Independent of the log switch -- the periodic correction timer calls this
// too, so sm_zstat always has a value available.
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

	// ---- measured tick (see SampleTick) ----
	SampleTick();
	float tickRate = g_fLastTickRate;
	float ftMs     = g_fLastFtMs;
	float fps      = (ftMs > 0.0) ? (1000.0 / ftMs) : -1.0;

	int cap  = (g_hEngine[P_COMMON] != null) ? g_hEngine[P_COMMON].IntValue : -1;
	int mmin = (g_hEngine[P_MOBMIN] != null) ? g_hEngine[P_MOBMIN].IntValue : -1;
	int mmax = (g_hEngine[P_MOBMAX] != null) ? g_hEngine[P_MOBMAX].IntValue : -1;
	int mega = (g_hEngine[P_MEGA]   != null) ? g_hEngine[P_MEGA].IntValue   : -1;

	// wanderer density / background limit / spread params
	// (written to the log to make A/B comparison easy)
	float dens = (g_hEngineF[FP_DENSITY] != null) ? g_hEngineF[FP_DENSITY].FloatValue : -1.0;
	float bg   = (g_hEngineF[FP_BGLIMIT] != null) ? g_hEngineF[FP_BGLIMIT].FloatValue : -1.0;
	int   sreg = (g_hEngineS[SP_REGION]  != null) ? g_hEngineS[SP_REGION].IntValue  : -1;
	int   ssaf = (g_hEngineS[SP_SAFETY]  != null) ? g_hEngineS[SP_SAFETY].IntValue  : -1;
	int   sran = (g_hEngineS[SP_RANGE]   != null) ? g_hEngineS[SP_RANGE].IntValue   : -1;

	float mobLeft = -1.0;
	if (LibraryExists("left4dhooks"))
		mobLeft = L4D2_CTimerGetCountdownDuration(L4D2CT_MobSpawnTimer);

	// spawn distribution: bins = occupied 500-unit buckets,
	// maxbin = commons in the most crowded bucket
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

	// ---- v1.8.2: tick warning (lines "tick drop" up with "how many zombies") ----
	// Only written when there are real players and the tick truly dropped, to
	// avoid false alarms on an idle server
	int warnAt = g_hCvTickWarn.IntValue;
	if (warnAt > 0 && tickRate > 0.0 && tickRate < float(warnAt) && players > 0)
	{
		LogToFileEx(g_szLogFile,
			"===== TICKWARN | %s | measured %.1f tick/s | frame %.2f ms | alive %d | cap %d | peak %d | spawned %d | SI %d | pulse %s(%d->%d) | horde in %.0f s =====",
			stamp, tickRate, ftMs, alive, cap, g_iPeakAlive,
			g_iSpawnWindow, si,
			g_bPulseOn ? "ON" : "OFF", g_iCapBase, g_bPulseOn ? g_iCapPulse : g_iCapBase,
			mobLeft);
	}

	g_iSpawnWindow = 0;
	g_iRecCount++;
}

/* ------------------------------------------------------------------ */
/*  Map change / config: apply values only, never touch timers here.    */
/*  (An older build killed a stale handle here, the exception aborted   */
/*   CreateTimer, and periodic correction died permanently.)            */
/* ------------------------------------------------------------------ */
public void OnMapStart()
{
	g_iPeakAlive = 0;
	// reset pulse state on map change so the previous map's countdown
	// / hold window does not carry over
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
		return;                     // already running, do not create a duplicate

	float interval = g_hCvInterval.FloatValue;
	if (interval <= 0.0)
		return;

	// Note: no TIMER_FLAG_NO_MAPCHANGE -- it must survive map changes
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
	SampleTick();              // v1.8.2: sample tick in passing (independent of the log switch)
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
/*  Counting                                                           */
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
		if (GetClientTeam(i) != 2)   // 2 = survivors
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
		if (GetClientTeam(i) == 3)   // 3 = infected
			n++;
	}
	return n;
}

/* ------------------------------------------------------------------ */
/*  Core: compute the final value of one parameter                     */
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
/*  compute a float parameter (wanderer density / background)   */
/*  Same formula as the integer version: base + extra * step -> clamp   */
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
/*  compute a spread parameter                                 */
/*  Linearly interpolates between [ _min (low player count) ,          */
/*  _max (high player count) ] by player count.                        */
/*  Example: low=4 high=8, 6 players -> the 50% point.                  */
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

	// below the start / at the end: use the endpoints directly
	if (players <= pLow)
		return lo;
	if (players >= pHigh)
		return hi;

	// linear interpolation in between
	float t = float(players - pLow) / float(pHigh - pLow);
	return RoundToNearest(float(lo) + t * float(hi - lo));
}

/* ------------------------------------------------------------------ */
/*  Apply                                                              */
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

	// horde "minimum" must never exceed "maximum"
	if (values[P_MOBMIN] > values[P_MOBMAX])
		values[P_MOBMIN] = values[P_MOBMAX];

	// ---- wanderer density / background limit (float) ----
	float fvalues[FPARAM_COUNT];
	for (int i = 0; i < FPARAM_COUNT; i++)
		fvalues[i] = ComputeParamF(i, extra);

	// ---- spread parameters (interpolated by real player count) ----
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
		// when pulse is enabled, z_common_limit is written below in one
		// place instead, to avoid writing it twice per frame and oscillating
		if (i == P_COMMON && g_hCvPulseEnable.BoolValue)
			continue;
		if (g_hEngine[i].IntValue == values[i])
			continue;

		g_hEngine[i].SetInt(values[i]);
		changed = true;
	}

	// ---- pulse: final value of z_common_limit ----
	// NOTE: this deliberately uses g_iCapPulse (already protected by
	//       l4d2_pulse_cap_max) and does NOT go through ComputeParam's global
	//       ceiling clamp -- the whole point of the pulse is to break it.
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

	// float parameters (compare with a small tolerance so float jitter does not
	// cause a rewrite every 1.5 seconds)
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

	// spread parameters (integer)
	// NOTE: when l4d2_spread_off=1 it writes back the _min value (usually the
	//       vanilla value) rather than skipping the write. An early
	//       implementation simply skipped the write, which left the engine
	//       stuck at the enlarged value and made it impossible to cleanly
	//       revert. Now: off = actively reset to _min.
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

	// peak tracking (used by sm_zstat)
	int alive = CountAliveCommons();
	if (alive > g_iPeakAlive)
		g_iPeakAlive = alive;

	// NOTE: use effCap (= the real cap after pulsing) rather than
	//       values[P_COMMON], otherwise force_trim would delete the horde it
	//       just let in while the headroom is open.
	if (g_hCvForceTrim.BoolValue && alive > effCap)
		TrimTo(effCap);

	if (announce && g_hCvHint.BoolValue && changed)
	{
		PrintToChatAll("\x04[Zombies]\x01 %d survivors -> alive cap \x03%d\x01, horde \x03%d-%d\x01, alert \x03%d\x01, wander density \x03%.2f",
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
/*  sm_zombies -- config view                                          */
/* ------------------------------------------------------------------ */
public Action Cmd_Zombies(int client, int args)
{
	if (!g_hCvEnable.BoolValue)
	{
		ReplyToCommand(client, "[Zombies] plugin disabled (plugin_enable 0)");
		return Plugin_Handled;
	}

	int players = CountSurvivors();
	int extra = (g_hCvDynamic.BoolValue && players > g_hCvThreshold.IntValue)
		? players - g_hCvThreshold.IntValue : 0;

	ReplyToCommand(client, "[Zombies] %d survivors%s | bonus tiers +%d | global ceiling %d | plugin v%s",
		players, g_hCvTestPlayers.IntValue > 0 ? " (test mode)" : "",
		extra, g_hCvGlobalCap.IntValue, PLUGIN_VERSION);

	for (int i = 0; i < PARAM_COUNT; i++)
	{
		int step  = g_hCvStep[i].IntValue;
		int raw   = g_hCvBase[i].IntValue + extra * step;
		int final = ComputeParam(i, extra);
		if (i == P_MOBMIN && final > g_hCvMax[P_MOBMAX].IntValue)
			final = g_hCvMax[P_MOBMAX].IntValue;
		int engine = (g_hEngine[i] != null) ? g_hEngine[i].IntValue : -1;

		ReplyToCommand(client, "  [%s] %s (%s): computed %d <- raw %d, range [%d, %d], engine now %d",
			g_szEngine[i], g_szLabel[i], step == 0 ? "fixed" : "scaled",
			final, raw, g_hCvMin[i].IntValue, g_hCvMax[i].IntValue, engine);
	}

	// ---- float parameters ----
	for (int i = 0; i < FPARAM_COUNT; i++)
	{
		float stepF  = g_hCvFStep[i].FloatValue;
		float rawF   = g_hCvFBase[i].FloatValue + float(extra) * stepF;
		float finalF = ComputeParamF(i, extra);
		float engineF = (g_hEngineF[i] != null) ? g_hEngineF[i].FloatValue : -1.0;

		ReplyToCommand(client, "  [%s] %s (%s): computed %.3f <- raw %.3f, range [%.3f, %.3f], engine now %.3f",
			g_szEngineF[i], g_szLabelF[i], stepF == 0.0 ? "fixed" : "scaled",
			finalF, rawF, g_hCvFMin[i].FloatValue, g_hCvFMax[i].FloatValue, engineF);
	}

	// ---- spread parameters ----
	if (g_hCvSpreadOff.BoolValue)
	{
		ReplyToCommand(client, "  [Spread] disabled (l4d2_spread_off 1) -- reset to the _min values (vanilla)");
		for (int i = 0; i < SP_COUNT; i++)
		{
			int engineS = (g_hEngineS[i] != null) ? g_hEngineS[i].IntValue : -1;
			ReplyToCommand(client, "  [%s] %s: reset target %d, engine now %d",
				g_szEngineS[i], g_szLabelS[i], g_hCvSpreadMin[i].IntValue, engineS);
		}
	}
	else
	{
		for (int i = 0; i < SP_COUNT; i++)
		{
			int sv = ComputeParamS(i, players);
			int engineS = (g_hEngineS[i] != null) ? g_hEngineS[i].IntValue : -1;
			ReplyToCommand(client, "  [%s] %s: interpolated %d (range %d~%d), engine now %d",
				g_szEngineS[i], g_szLabelS[i], sv,
				g_hCvSpreadMin[i].IntValue, g_hCvSpreadMax[i].IntValue, engineS);
		}
		ReplyToCommand(client, "   (interpolation endpoints: _min at %d players, _max at %d players, linear in between)",
			g_hCvSpreadLow.IntValue, g_hCvSpreadHigh.IntValue);
	}

	return Plugin_Handled;
}

/* ------------------------------------------------------------------ */
/*  sm_zstat -- battlefield view (the command you tune with)           */
/* ------------------------------------------------------------------ */
public Action Cmd_ZStat(int client, int args)
{
	if (!g_hCvEnable.BoolValue)
	{
		ReplyToCommand(client, "[ZStat] plugin disabled (plugin_enable 0)");
		return Plugin_Handled;
	}

	if (args >= 1)
	{
		char arg[16];
		GetCmdArg(1, arg, sizeof(arg));
		if (StrEqual(arg, "reset", false))
		{
			g_iPeakAlive = CountAliveCommons();
			ReplyToCommand(client, "[ZStat] peak reset to %d", g_iPeakAlive);
			return Plugin_Handled;
		}
	}

	int players = CountSurvivors();
	int commons = CountAliveCommons();
	int si      = CountSpecialInfected();
	int witch   = CountEntitiesOfClass("witch");
	int tank    = CountEntitiesOfClass("tank");
	int cap     = (g_hEngine[P_COMMON] != null) ? g_hEngine[P_COMMON].IntValue : -1;

	ReplyToCommand(client, "[ZStat] %d survivors | live commons \x03%d\x01 / cap %d | peak %d",
		players, commons, cap, g_iPeakAlive);
	ReplyToCommand(client, "        special infected %d | Witch %d | Tank %d", si, witch, tank);

	if (LibraryExists("left4dhooks"))
	{
		float left = L4D2_CTimerGetCountdownDuration(L4D2CT_MobSpawnTimer);
		ReplyToCommand(client, "        next natural horde in: %.0f s", left);
	}

	// measured tick / frame time (this line tells you if the server is stable)
	{
		char tickBuf[96];
		char rateBuf[32];
		if (g_fLastTickRate > 0.0)
			Format(rateBuf, sizeof(rateBuf), "%.1f", g_fLastTickRate);
		else
			Format(rateBuf, sizeof(rateBuf), "sampling");

		if (g_fLastFtMs > 0.0)
		{
			Format(tickBuf, sizeof(tickBuf), "        measured tick: \x03%s\x01 tick/s (target 64) | frame \x03%.2f\x01 ms | FPS ~%.0f",
				rateBuf, g_fLastFtMs, 1000.0 / g_fLastFtMs);
			ReplyToCommand(client, "%s", tickBuf);
		}
		else
			ReplyToCommand(client, "        measured tick: \x03%s\x01 tick/s | frame: no data (idle/paused)", rateBuf);
	}

	// pulse state -- this line tells you whether a horde has room to land
	if (g_hCvPulseEnable.BoolValue)
	{
		ReplyToCommand(client, "        horde pulse: \x03%s\x01 | mode %d | base cap %d + headroom %d = %d | opened \x03%d\x01 times",
			g_bPulseOn ? "OPEN" : "idle", g_hCvPulseMode.IntValue,
			g_iCapBase, g_iHeadroom, g_iCapPulse, g_iPulseFires);
		if (!g_bPulseOn && cap > 0 && g_iCapBase > 0 && cap != g_iCapBase)
			ReplyToCommand(client, "                 ! engine value %d != expected %d -- possibly overridden by a map script", cap, g_iCapBase);
	}

	// spawn distribution
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
			ReplyToCommand(client, "        spread: occupying \x03%d\x01 buckets of 500 units | busiest bucket \x03%d\x01 | span %d",
				bins, maxbin, span);
			ReplyToCommand(client, "                 (more buckets = more spread; a busiest bucket above 1/4 of the alive count means clumping)");
		}
	}

	ReplyToCommand(client, "        engine now: common=%d mob=%d-%d mega=%d | periodic correction %s",
		cap,
		g_hEngine[P_MOBMIN] != null ? g_hEngine[P_MOBMIN].IntValue : -1,
		g_hEngine[P_MOBMAX] != null ? g_hEngine[P_MOBMAX].IntValue : -1,
		g_hEngine[P_MEGA]   != null ? g_hEngine[P_MEGA].IntValue   : -1,
		g_hTimer != null ? "running" : "stopped");

	// wanderer density / background limit / spread -- the real switches
	// for "is the map empty, is it clumped"
	{
		char szDens[48] = "-";
		char szBg[48]   = "-";
		if (g_hEngineF[FP_DENSITY] != null)
			Format(szDens, sizeof(szDens), "%.3f", g_hEngineF[FP_DENSITY].FloatValue);
		if (g_hEngineF[FP_BGLIMIT] != null)
			Format(szBg, sizeof(szBg), "%.0f", g_hEngineF[FP_BGLIMIT].FloatValue);

		if (g_hCvSpreadOff.BoolValue)
		{
			ReplyToCommand(client, "        wander density %s | background %s | spread control disabled",
				szDens, szBg);
		}
		else
		{
			ReplyToCommand(client, "        wander density \x03%s\x01 | background %s | spread \x03%d/%d/%d\x01 (region/safety/range)",
				szDens, szBg,
				g_hEngineS[SP_REGION] != null ? g_hEngineS[SP_REGION].IntValue : -1,
				g_hEngineS[SP_SAFETY] != null ? g_hEngineS[SP_SAFETY].IntValue : -1,
				g_hEngineS[SP_RANGE]  != null ? g_hEngineS[SP_RANGE].IntValue  : -1);
		}
	}

	return Plugin_Handled;
}
