// Windows OS adapter: dynamic WFP session, never changes the user's firewall policy.
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <windows.h>
#include <initguid.h>
#include <fwpmu.h>
#include <stdint.h>
#include <ws2ipdef.h>

__declspec(dllexport) DWORD cgp_windows_dns_filter_open(HANDLE *result) {
    *result = NULL;
    FWPM_SESSION0 session = {0};
    session.displayData.name = L"ChatGPT Proxy DNS protection";
    session.flags = FWPM_SESSION_FLAG_DYNAMIC;
    HANDLE engine = NULL;
    DWORD error = FwpmEngineOpen0(NULL, RPC_C_AUTHN_WINNT, NULL, &session, &engine);
    if (error) return error;
    error = FwpmTransactionBegin0(engine, 0);
    if (error) goto fail;
    const GUID *layers[] = {&FWPM_LAYER_OUTBOUND_TRANSPORT_V4, &FWPM_LAYER_OUTBOUND_TRANSPORT_V6};
    const UINT8 protocols[] = {IPPROTO_TCP, IPPROTO_UDP};
    for (int layer = 0; layer < 2; ++layer) {
        for (int protocol = 0; protocol < 2; ++protocol) {
            FWPM_FILTER_CONDITION0 conditions[3] = {0};
            conditions[0].fieldKey = FWPM_CONDITION_IP_REMOTE_PORT;
            conditions[0].matchType = FWP_MATCH_EQUAL;
            conditions[0].conditionValue.type = FWP_UINT16;
            conditions[0].conditionValue.uint16 = 53;
            conditions[1].fieldKey = FWPM_CONDITION_IP_PROTOCOL;
            conditions[1].matchType = FWP_MATCH_EQUAL;
            conditions[1].conditionValue.type = FWP_UINT8;
            conditions[1].conditionValue.uint8 = protocols[protocol];
            conditions[2].fieldKey = FWPM_CONDITION_FLAGS;
            conditions[2].matchType = FWP_MATCH_FLAGS_NONE_SET;
            conditions[2].conditionValue.type = FWP_UINT32;
            conditions[2].conditionValue.uint32 = FWP_CONDITION_FLAG_IS_LOOPBACK;
            FWPM_FILTER0 filter = {0};
            filter.displayData.name = L"ChatGPT Proxy: block external plaintext DNS";
            filter.layerKey = *layers[layer];
            filter.weight.type = FWP_EMPTY;
            filter.action.type = FWP_ACTION_BLOCK;
            filter.numFilterConditions = 3;
            filter.filterCondition = conditions;
            error = FwpmFilterAdd0(engine, &filter, NULL, NULL);
            if (error) { FwpmTransactionAbort0(engine); goto fail; }
        }
    }
    error = FwpmTransactionCommit0(engine);
    if (error) goto fail;
    *result = engine;
    return ERROR_SUCCESS;
fail:
    FwpmEngineClose0(engine);
    return error;
}
__declspec(dllexport) DWORD cgp_windows_dns_filter_close(HANDLE handle) {
    return handle ? FwpmEngineClose0(handle) : ERROR_SUCCESS;
}
