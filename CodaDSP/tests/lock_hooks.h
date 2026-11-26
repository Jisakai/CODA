#pragma once
#include <stdint.h>
#if defined(__APPLE__)
#ifdef __cplusplus
extern "C" {
#endif
void coda_test_lock_begin(void);
void coda_test_lock_end(void);
uint64_t coda_test_lock_count(void);
#ifdef __cplusplus
}
#endif
#endif
