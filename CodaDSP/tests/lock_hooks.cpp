// Test-only separate image: dyld excludes this image from its replacements,
// allowing wrappers to call the original functions without recursion.
#include "lock_hooks.h"
#if defined(__APPLE__)
#include <pthread.h>
#include <os/lock.h>
#include <atomic>
#include <dlfcn.h>
#include <cstdio>
// Never access Darwin dynamic TLS inside an interposed lock: first-use TLS
// resolution may itself lock, recursively entering this wrapper before main.
// One instrumented render consumer at a time; other threads are excluded by ID.
static std::atomic<uintptr_t> enabled_thread{0};
static std::atomic<uint64_t> lock_count{0};
static_assert(std::atomic<uintptr_t>::is_always_lock_free);
static_assert(std::atomic<uint64_t>::is_always_lock_free);
extern "C" void coda_test_lock_begin(void) {
    const auto thread=reinterpret_cast<uintptr_t>(pthread_self());
    lock_count.store(0,std::memory_order_relaxed);
    enabled_thread.store(thread,std::memory_order_relaxed);
}
extern "C" void coda_test_lock_end(void) {enabled_thread.store(0,std::memory_order_relaxed);}
extern "C" uint64_t coda_test_lock_count(void) {return lock_count.load(std::memory_order_relaxed);}
static void record_lock() {
    const auto thread=enabled_thread.load(std::memory_order_relaxed);
    if(thread && thread==reinterpret_cast<uintptr_t>(pthread_self())) lock_count.fetch_add(1,std::memory_order_relaxed);
}
static int checked_mutex_lock(pthread_mutex_t *m) {
    record_lock();return pthread_mutex_lock(m);
}
static void checked_unfair_lock(os_unfair_lock_t m) {
    record_lock();os_unfair_lock_lock(m);
}
#define CODA_INTERPOSE(replacement, original) \
    __attribute__((used)) static struct { const void *replace; const void *original; } \
    interpose_##original __attribute__((section("__DATA,__interpose"))) = \
    {reinterpret_cast<const void *>(&replacement),reinterpret_cast<const void *>(&original)};
CODA_INTERPOSE(checked_mutex_lock,pthread_mutex_lock)
CODA_INTERPOSE(checked_unfair_lock,os_unfair_lock_lock)
#endif

#if defined(__APPLE__)
static void describe_symbol(const char *label, const void *address) {
    Dl_info info{};
    const int found=address ? dladdr(address,&info) : 0;
    std::fprintf(stderr,"lock binding %s=%p image=%s symbol=%s base=%p\n",
        label,address,found&&info.dli_fname?info.dli_fname:"<unknown>",
        found&&info.dli_sname?info.dli_sname:"<unknown>",found?info.dli_fbase:nullptr);
}
extern "C" void coda_test_lock_diagnostics(const char *phase, uint64_t observed,
        uint64_t expected, const void *caller_mutex, const void *caller_unfair) {
    // Always outside the measured interval. Do not infer a working call chain
    // from symbol addresses alone: the real-lock calibration is authoritative.
    std::fprintf(stderr,"lock calibration %s observed=%llu expected=%llu\n",phase,
        static_cast<unsigned long long>(observed),static_cast<unsigned long long>(expected));
    describe_symbol("caller mutex",caller_mutex);
    describe_symbol("caller unfair",caller_unfair);
    describe_symbol("hook mutex forward",reinterpret_cast<const void *>(&pthread_mutex_lock));
    describe_symbol("hook unfair forward",reinterpret_cast<const void *>(&os_unfair_lock_lock));
    describe_symbol("mutex wrapper",reinterpret_cast<const void *>(&checked_mutex_lock));
    describe_symbol("unfair wrapper",reinterpret_cast<const void *>(&checked_unfair_lock));
    describe_symbol("default mutex",dlsym(RTLD_DEFAULT,"pthread_mutex_lock"));
    describe_symbol("next mutex",dlsym(RTLD_NEXT,"pthread_mutex_lock"));
    describe_symbol("default unfair",dlsym(RTLD_DEFAULT,"os_unfair_lock_lock"));
    describe_symbol("asan runtime",dlsym(RTLD_DEFAULT,"__asan_init"));
}
#endif
