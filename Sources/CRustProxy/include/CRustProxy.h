#ifndef CGP_RUST_PROXY_H
#define CGP_RUST_PROXY_H
#include <stdint.h>
#include <stddef.h>
typedef struct CGPCoreEngine CGPCoreEngine;
typedef struct { uint8_t *data; size_t len; } CGPCoreBuffer;
uint32_t cgp_core_abi_version(void);
CGPCoreEngine *cgp_core_create(void);
/* Calls may overlap, but destroy requires exclusive ownership. Inputs borrowed for call only. */
CGPCoreBuffer cgp_core_call(CGPCoreEngine *, const uint8_t *, size_t);
void cgp_core_buffer_free(CGPCoreBuffer);
void cgp_core_destroy(CGPCoreEngine *);
#endif
