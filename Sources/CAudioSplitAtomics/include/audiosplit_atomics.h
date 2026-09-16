#ifndef AUDIOSPLIT_ATOMICS_H
#define AUDIOSPLIT_ATOMICS_H

#include <stdint.h>

/// Per-route realtime parameters and telemetry.
///
/// Swift's `Synchronization.Atomic` would express this directly, but it requires
/// macOS 15 and AudioSplit supports 14.4. These relaxed atomics compile to plain
/// aligned loads and stores on arm64 — the realtime thread never blocks, and
/// neither side ever sees a torn value.
///
/// The accessors take the whole slot rather than a field address on purpose:
/// Swift's inout-to-pointer conversion may hand back a temporary copy, which
/// would silently make the operation non-atomic.
typedef struct {
    uint32_t gain_bits;   /// linear gain, as a float bit pattern
    uint32_t muted;
    uint32_t peak_bits;   /// most recent peak magnitude, as a float bit pattern
    uint32_t delay_frames;/// delay in frames, already converted from milliseconds
    uint64_t frames_rendered;
} as_tap_slot;

static inline uint32_t as_slot_gain_bits(const as_tap_slot *slot) {
    return __atomic_load_n(&slot->gain_bits, __ATOMIC_RELAXED);
}

static inline void as_slot_set_gain_bits(as_tap_slot *slot, uint32_t bits) {
    __atomic_store_n(&slot->gain_bits, bits, __ATOMIC_RELAXED);
}

static inline uint32_t as_slot_muted(const as_tap_slot *slot) {
    return __atomic_load_n(&slot->muted, __ATOMIC_RELAXED);
}

static inline void as_slot_set_muted(as_tap_slot *slot, uint32_t muted) {
    __atomic_store_n(&slot->muted, muted, __ATOMIC_RELAXED);
}

static inline uint32_t as_slot_peak_bits(const as_tap_slot *slot) {
    return __atomic_load_n(&slot->peak_bits, __ATOMIC_RELAXED);
}

static inline void as_slot_set_peak_bits(as_tap_slot *slot, uint32_t bits) {
    __atomic_store_n(&slot->peak_bits, bits, __ATOMIC_RELAXED);
}

static inline uint32_t as_slot_delay_frames(const as_tap_slot *slot) {
    return __atomic_load_n(&slot->delay_frames, __ATOMIC_RELAXED);
}

static inline void as_slot_set_delay_frames(as_tap_slot *slot, uint32_t frames) {
    __atomic_store_n(&slot->delay_frames, frames, __ATOMIC_RELAXED);
}

static inline uint64_t as_slot_frames_rendered(const as_tap_slot *slot) {
    return __atomic_load_n(&slot->frames_rendered, __ATOMIC_RELAXED);
}

static inline void as_slot_add_frames(as_tap_slot *slot, uint64_t frames) {
    __atomic_fetch_add(&slot->frames_rendered, frames, __ATOMIC_RELAXED);
}

static inline void as_slot_init(as_tap_slot *slot, uint32_t gain_bits, uint32_t muted) {
    slot->gain_bits = gain_bits;
    slot->muted = muted;
    slot->peak_bits = 0;
    slot->delay_frames = 0;
    slot->frames_rendered = 0;
}

#endif
