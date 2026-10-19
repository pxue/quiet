// C ABI exported by dfcore (Rust, DeepFilterNet3 via tract). See dfcore/src/lib.rs.
#pragma once
#include <stddef.h>

typedef struct Denoiser Denoiser;

Denoiser *df_new(float atten_lim_db);
size_t df_frame_len(const Denoiser *d);
size_t df_sample_rate(const Denoiser *d);
void df_set_atten_lim(Denoiser *d, float atten_lim_db);
float df_process(Denoiser *d, const float *input, float *output);
void df_free(Denoiser *d);
