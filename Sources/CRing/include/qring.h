// Lock-free single-producer/single-consumer float ring buffer, safe to use from CoreAudio IO threads.
#pragma once
#include <stdint.h>

typedef struct qring qring;

qring *qring_new(uint32_t capacity);
void qring_free(qring *r);
uint32_t qring_write(qring *r, const float *src, uint32_t n);
uint32_t qring_read(qring *r, float *dst, uint32_t n);
uint32_t qring_skip(qring *r, uint32_t n);
uint32_t qring_available(const qring *r);
