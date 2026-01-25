#pragma semicolon 1
#pragma newdecls required

// ================================================================
// Includes
// ================================================================

#include <sourcemod>
#include <dhooks>

// ================================================================
// Info
// ================================================================

public Plugin myinfo = {
    name        = "Anti-Speed",
    author      = "RenardDev",
    description = "Fix for RapidFire/SpeedHack",
    version     = "1.1.0",
    url         = "https://github.com/RenardDev/AntiSpeed"
};

// ================================================================
// ConVars
// ================================================================

ConVar g_ConVarEnable;
ConVar g_ConVarMaxNewUserCmds;
ConVar g_ConVarPingSlackTicks;

// ================================================================
// DHooks
// ================================================================

GameData    g_hGameData;
DynamicHook g_hHookProcessUserCmds;

// Per-client hook id
int g_nHookIDPre[MAXPLAYERS + 1] = { INVALID_HOOK_ID, ... };

// ================================================================
// State
// ================================================================

// Token-bucket state
int g_nTokenTicks[MAXPLAYERS + 1];
int g_nLastServerTickSeen[MAXPLAYERS + 1];

// Cached cap (max + slack)
int g_nCachedCapTicks = 0;

// ================================================================
// Utils
// ================================================================

static int ClampInt(int nValue, int nMin, int nMax) {
    if (nValue < nMin) {
        return nMin;
    }

    if (nValue > nMax) {
        return nMax;
    }

    return nValue;
}

static void UpdateCachedCapTicks() {
    int nMaxNewUserCmds = g_ConVarMaxNewUserCmds.IntValue;
    int nPingSlackTicks = g_ConVarPingSlackTicks.IntValue;

    if (nMaxNewUserCmds < 0) {
        nMaxNewUserCmds = 0;
    }

    if (nPingSlackTicks < 0) {
        nPingSlackTicks = 0;
    }

    g_nCachedCapTicks = ClampInt(nMaxNewUserCmds + nPingSlackTicks, 0, 2048);
}

static void ResetClientState(int nClient, int nServerTickNow = -1) {
    if (nServerTickNow < 0) {
        nServerTickNow = GetGameTickCount();
    }

    g_nTokenTicks[nClient] = g_nCachedCapTicks;
    g_nLastServerTickSeen[nClient] = nServerTickNow;
}

static void UnhookClient(int nClient) {
    if (g_nHookIDPre[nClient] != INVALID_HOOK_ID) {
        DynamicHook.RemoveHook(g_nHookIDPre[nClient]);
        g_nHookIDPre[nClient] = INVALID_HOOK_ID;
    }
}

static void HookClient(int nClient) {
    if (!IsClientInGame(nClient) || IsFakeClient(nClient)) {
        return;
    }

    UnhookClient(nClient);

    g_nHookIDPre[nClient] = g_hHookProcessUserCmds.HookEntity(Hook_Pre, nClient, Hook_ProcessUserCmds_Pre);

    ResetClientState(nClient);
}

static void HookAllClients() {
    for (int nClient = 1; nClient <= MaxClients; nClient++) {
        if (IsClientInGame(nClient) && !IsFakeClient(nClient)) {
            HookClient(nClient);
        } else {
            UnhookClient(nClient);
        }
    }
}

static void UnhookAllClients() {
    for (int nClient = 1; nClient <= MaxClients; nClient++) {
        UnhookClient(nClient);
    }
}

// ================================================================
// ConVar change hooks
// ================================================================

public void OnConVarChanged_Enable(ConVar hConVar, const char[] sOldValue, const char[] sNewValue) {
    if (g_ConVarEnable.BoolValue) {
        HookAllClients();
        return;
    }

    UnhookAllClients();
}

public void OnConVarChanged_MaxNewUserCmds(ConVar hConVar, const char[] sOldValue, const char[] sNewValue) {
    UpdateCachedCapTicks();

    for (int nClient = 1; nClient <= MaxClients; nClient++) {
        if (g_nTokenTicks[nClient] > g_nCachedCapTicks) {
            g_nTokenTicks[nClient] = g_nCachedCapTicks;
        }
    }
}

public void OnConVarChanged_PingSlackTicks(ConVar hConVar, const char[] sOldValue, const char[] sNewValue) {
    UpdateCachedCapTicks();

    for (int nClient = 1; nClient <= MaxClients; nClient++) {
        if (g_nTokenTicks[nClient] > g_nCachedCapTicks) {
            g_nTokenTicks[nClient] = g_nCachedCapTicks;
        }
    }
}

// ================================================================
// Plugin lifecycle
// ================================================================

public void OnPluginStart() {
    g_ConVarEnable = CreateConVar(
        "sm_antispeed_enable", "1",
        "Enable Anti-Speed (0/1)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );

    g_ConVarMaxNewUserCmds = CreateConVar(
        "sm_antispeed_max", "24",
        "Max NEW usercmds worth of backlog allowed",
        FCVAR_NOTIFY, true, 0.0, true, 2048.0
    );

    g_ConVarPingSlackTicks = CreateConVar(
        "sm_antispeed_ping_slack", "4",
        "Extra ticks added to cap to tolerate jitter/ping fluctuations",
        FCVAR_NOTIFY, true, 0.0, true, 512.0
    );

    AutoExecConfig(true, "antispeed");

    g_hGameData = new GameData("antispeed.l4d2");
    if (g_hGameData == null) {
        SetFailState("Failed to load gamedata: antispeed.l4d2");
    }

    g_hHookProcessUserCmds = DynamicHook.FromConf(g_hGameData, "CBasePlayer::ProcessUsercmds");
    if (g_hHookProcessUserCmds == null) {
        SetFailState("Failed to find function in gamedata: CBasePlayer::ProcessUsercmds");
    }

    UpdateCachedCapTicks();

    g_ConVarEnable.AddChangeHook(OnConVarChanged_Enable);
    g_ConVarMaxNewUserCmds.AddChangeHook(OnConVarChanged_MaxNewUserCmds);
    g_ConVarPingSlackTicks.AddChangeHook(OnConVarChanged_PingSlackTicks);

    if (g_ConVarEnable.BoolValue) {
        HookAllClients();
    }
}

public void OnPluginEnd() {
    UnhookAllClients();
}

public void OnMapStart() {
    if (g_ConVarEnable.BoolValue) {
        HookAllClients();
        return;
    }

    UnhookAllClients();
}

public void OnClientPutInServer(int nClient) {
    if (!g_ConVarEnable.BoolValue) {
        return;
    }

    if (!IsClientInGame(nClient) || IsFakeClient(nClient)) {
        return;
    }

    HookClient(nClient);
}

public void OnClientDisconnect(int nClient) {
    UnhookClient(nClient);
    ResetClientState(nClient);
}

// ================================================================
// DHooks callback
// ================================================================

// return "void" => callback MUST be (int this, DHookParam params)
public MRESReturn Hook_ProcessUserCmds_Pre(int nClient, DHookParam hParams) {
    if (!g_ConVarEnable.BoolValue) {
        return MRES_Ignored;
    }

    if ((nClient <= 0) || (nClient > MaxClients)) {
        return MRES_Ignored;
    }

    if (!IsClientInGame(nClient) || IsFakeClient(nClient)) {
        return MRES_Ignored;
    }

    int nNewUserCmds = hParams.Get(2);
    int nTotalUserCmds = hParams.Get(3);

    if (nNewUserCmds < 0) {
        nNewUserCmds = 0;
    }

    if (nTotalUserCmds < nNewUserCmds) {
        nTotalUserCmds = nNewUserCmds;
    }

    int nBackupUserCmds = nTotalUserCmds - nNewUserCmds;
    if (nBackupUserCmds < 0) {
        nBackupUserCmds = 0;
    }

    int nServerTickNow = GetGameTickCount();
    int nLastServerTick = g_nLastServerTickSeen[nClient];

    int nDeltaServerTicks = (nLastServerTick > 0) ? (nServerTickNow - nLastServerTick) : 1;
    if ((nDeltaServerTicks < 0) || (nDeltaServerTicks > 4096)) {
        nDeltaServerTicks = 1;
    }

    if (nLastServerTick <= 0) {
        g_nTokenTicks[nClient] = g_nCachedCapTicks;
    } else {
        g_nTokenTicks[nClient] = ClampInt(g_nTokenTicks[nClient] + nDeltaServerTicks, 0, g_nCachedCapTicks);
    }

    g_nLastServerTickSeen[nClient] = nServerTickNow;

    int nAllowedNewUserCmds = nNewUserCmds;

    if (nAllowedNewUserCmds > g_nTokenTicks[nClient]) {
        nAllowedNewUserCmds = g_nTokenTicks[nClient];
    }

    if (nAllowedNewUserCmds < 0) {
        nAllowedNewUserCmds = 0;
    }

    int nIgnoredNewUserCmds = nNewUserCmds - nAllowedNewUserCmds;
    if (nIgnoredNewUserCmds < 0) {
        nIgnoredNewUserCmds = 0;
    }

    g_nTokenTicks[nClient] -= nAllowedNewUserCmds;
    if (g_nTokenTicks[nClient] < 0) {
        g_nTokenTicks[nClient] = 0;
    }

    if (nIgnoredNewUserCmds > 0) {
        int nNewTotalUserCmds = nBackupUserCmds + nAllowedNewUserCmds;

        if (nNewTotalUserCmds < nAllowedNewUserCmds) {
            nNewTotalUserCmds = nAllowedNewUserCmds;
        }

        hParams.Set(2, nAllowedNewUserCmds);
        hParams.Set(3, nNewTotalUserCmds);

        return MRES_Handled;
    }

    return MRES_Ignored;
}
