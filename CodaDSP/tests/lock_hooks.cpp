// Test-only separate image: dyld excludes this image from its replacements,
// allowing wrappers to call the original functions without recursion.
#include "lock_hooks.h"
#if defined(__APPLE__)
#include <pthread.h>
#include <os/lock.h>
static thread_local bool enabled=false;
static thread_local uint64_t lock_count=0;
extern "C" void coda_test_lock_begin(void) {lock_count=0;enabled=true;}
extern "C" void coda_test_lock_end(void) {enabled=false;}
extern "C" uint64_t coda_test_lock_count(void) {return lock_count;}
static int checked_mutex_lock(pthread_mutex_t *m) {
    if(enabled)++lock_count;return pthread_mutex_lock(m);
}
static void checked_unfair_lock(os_unfair_lock_t m) {
    if(enabled)++lock_count;os_unfair_lock_lock(m);
}
#define CODA_INTERPOSE(replacement, original) \
    __attribute__((used)) static struct { const void *replace; const void *original; } \
    interpose_##original __attribute__((section("__DATA,__interpose"))) = \
    {reinterpret_cast<const void *>(&replacement),reinterpret_cast<const void *>(&original)};
CODA_INTERPOSE(checked_mutex_lock,pthread_mutex_lock)
CODA_INTERPOSE(checked_unfair_lock,os_unfair_lock_lock)
#endif
