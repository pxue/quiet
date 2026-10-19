#include "qring.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct qring {
    float *buf;
    uint32_t cap;
    _Atomic uint64_t w;
    _Atomic uint64_t r;
};

qring *qring_new(uint32_t capacity) {
    qring *q = calloc(1, sizeof(qring));
    q->buf = calloc(capacity, sizeof(float));
    q->cap = capacity;
    return q;
}

void qring_free(qring *q) {
    if (!q) return;
    free(q->buf);
    free(q);
}

uint32_t qring_available(const qring *q) {
    return (uint32_t)(atomic_load_explicit(&q->w, memory_order_acquire) -
                      atomic_load_explicit(&q->r, memory_order_acquire));
}

uint32_t qring_write(qring *q, const float *src, uint32_t n) {
    uint64_t w = atomic_load_explicit(&q->w, memory_order_relaxed);
    uint64_t r = atomic_load_explicit(&q->r, memory_order_acquire);
    uint32_t space = q->cap - (uint32_t)(w - r);
    if (n > space) n = space;
    uint32_t pos = (uint32_t)(w % q->cap), first = q->cap - pos;
    if (first > n) first = n;
    memcpy(q->buf + pos, src, first * sizeof(float));
    memcpy(q->buf, src + first, (n - first) * sizeof(float));
    atomic_store_explicit(&q->w, w + n, memory_order_release);
    return n;
}

uint32_t qring_read(qring *q, float *dst, uint32_t n) {
    uint64_t r = atomic_load_explicit(&q->r, memory_order_relaxed);
    uint64_t w = atomic_load_explicit(&q->w, memory_order_acquire);
    uint32_t avail = (uint32_t)(w - r);
    if (n > avail) n = avail;
    uint32_t pos = (uint32_t)(r % q->cap), first = q->cap - pos;
    if (first > n) first = n;
    memcpy(dst, q->buf + pos, first * sizeof(float));
    memcpy(dst + first, q->buf, (n - first) * sizeof(float));
    atomic_store_explicit(&q->r, r + n, memory_order_release);
    return n;
}

uint32_t qring_skip(qring *q, uint32_t n) {
    uint64_t r = atomic_load_explicit(&q->r, memory_order_relaxed);
    uint64_t w = atomic_load_explicit(&q->w, memory_order_acquire);
    uint32_t avail = (uint32_t)(w - r);
    if (n > avail) n = avail;
    atomic_store_explicit(&q->r, r + n, memory_order_release);
    return n;
}
