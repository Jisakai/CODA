#pragma once
#include <stdint.h>
#if defined(__APPLE__)
#ifdef __cplusplus
extern "C" {
#endif
void coda_test_lock_begin(void);
void coda_test_lock_end(void);
uint64_t coda_test_lock_count(void);
// Call only after counting ends; symbol lookup and stderr are not render-safe.
void coda_test_lock_diagnostics(const char *phase, uint64_t observed,
                                uint64_t expected, const void *caller_mutex,
                                const void *caller_unfair);
#ifdef __cplusplus
}
#endif
#endif
