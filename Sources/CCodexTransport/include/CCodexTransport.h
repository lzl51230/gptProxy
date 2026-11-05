#ifndef CGP_CODEX_TRANSPORT_H
#define CGP_CODEX_TRANSPORT_H

typedef struct CGPCodexSession CGPCodexSession;

/* All calls except cancel are confined to one serial worker. Cancel is thread-safe. */
CGPCodexSession *cgp_codex_create(const char *proxy, const char *target, const char *ca_file);
int cgp_codex_heartbeat(CGPCodexSession *session, long timeout_ms);
const char *cgp_codex_error(CGPCodexSession *session);
long cgp_codex_latency_ms(CGPCodexSession *session);
void cgp_codex_cancel(CGPCodexSession *session);
void cgp_codex_destroy(CGPCodexSession *session);

#endif
