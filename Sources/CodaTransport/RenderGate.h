#pragma once
#include "coda_transport.h"
#include <atomic>
#include <thread>

namespace coda {
inline constexpr uint64_t closedBit=uint64_t(1)<<63;
struct RenderGate {
    std::atomic<uint64_t> state{closedBit};
    CodaTransport *transport=nullptr;
    bool enter() noexcept {
        auto s=state.load(std::memory_order_acquire);
        // Bounded CAS. A close race or unexpected concurrent consumer returns
        // silence, never waits on the audio thread.
        if(s!=0) return false;
        return state.compare_exchange_strong(s,1,std::memory_order_acq_rel);
    }
    void leave() noexcept {state.fetch_sub(1,std::memory_order_release);}
    void close() {
        state.fetch_or(closedBit,std::memory_order_acq_rel);
        while(state.load(std::memory_order_acquire)!=closedBit) std::this_thread::yield();
    }
};
}
