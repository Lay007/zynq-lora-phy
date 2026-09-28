/*
 * lora_tx_noise -- stream LoRa test packets with fresh AWGN to the AD9361 DAC.
 *
 * Runs on the CLG400 board and writes interleaved int16 I/Q to stdout, meant
 * to be piped into iio_writedev (non-cyclic, so every sample is new):
 *
 *   lora_tx_noise templates.iq <packets> <samples_per_packet> <gap_samples>
 *                 <snr_db_in_bw> <bw_hz> <rms_dbfs> [seed]
 *     | iio_writedev -b 262144 cf-ad9361-dds-core-lpc
 *
 * templates.iq holds <packets> clean packets back to back, each exactly
 * <samples_per_packet> complex float32 samples of unit amplitude (made on the
 * host by tools/lora_tx_waveform.py --templates). The stream is template k,
 * then <gap_samples> of silence, for k = 0, 1, ... wrapping around, with
 * independent complex Gaussian noise added to *every* sample, so each packet
 * is an independent trial even though the templates repeat. The packets carry
 * distinct sequence numbers, so a receiver's misses show as gaps.
 *
 * SNR is defined in the signal bandwidth bw_hz at 1 MS/s: the noise is white
 * over the 1 MHz sample band with density N0 such that N0 * bw = 10^(-SNR/10)
 * (signal power 1). Output is scaled so that the stream's RMS sits at
 * rms_dbfs of int16 full scale; samples beyond full scale are clipped and
 * counted on stderr.
 */

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define SAMPLE_RATE 1000000.0

/* xoshiro128+ and a Marsaglia polar Gaussian: fast enough for 2 M normals/s
 * on the Cortex-A9. */
static uint32_t s[4];
static inline uint32_t rotl(uint32_t x, int k) { return (x << k) | (x >> (32 - k)); }
static inline uint32_t next32(void) {
  uint32_t r = s[0] + s[3], t = s[1] << 9;
  s[2] ^= s[0]; s[3] ^= s[1]; s[1] ^= s[2]; s[0] ^= s[3]; s[2] ^= t; s[3] = rotl(s[3], 11);
  return r;
}
static inline float uni(void) { return (next32() >> 8) * (1.0f / 16777216.0f) * 2.0f - 1.0f; }
static int have_spare;
static float spare;
static inline float gauss(void) {
  if (have_spare) { have_spare = 0; return spare; }
  float u, v, q;
  do { u = uni(); v = uni(); q = u * u + v * v; } while (q >= 1.0f || q == 0.0f);
  float m = sqrtf(-2.0f * logf(q) / q);
  spare = v * m; have_spare = 1;
  return u * m;
}

int main(int argc, char **argv) {
  if (argc < 8) {
    fprintf(stderr, "usage: %s templates.iq packets samples_per_packet gap_samples snr_db bw_hz rms_dbfs [seed]\n", argv[0]);
    return 2;
  }
  const char *path = argv[1];
  long packets = atol(argv[2]), spp = atol(argv[3]), gap = atol(argv[4]);
  double snr_db = atof(argv[5]), bw = atof(argv[6]), rms_dbfs = atof(argv[7]);
  uint32_t seed = argc > 8 ? (uint32_t)strtoul(argv[8], NULL, 0) : 1u;
  s[0] = seed ^ 0x9E3779B9u; s[1] = 0x243F6A88u; s[2] = 0xB7E15162u ^ seed; s[3] = 0x7F4A7C15u;
  for (int i = 0; i < 16; ++i) next32();

  size_t n = (size_t)packets * spp * 2;
  float *tpl = malloc(n * sizeof(float));
  FILE *f = fopen(path, "rb");
  if (!tpl || !f || fread(tpl, sizeof(float), n, f) != n) { fprintf(stderr, "cannot read %s\n", path); return 1; }
  fclose(f);

  /* Noise per real component: total complex variance N0 * fs. */
  double n0 = pow(10.0, -snr_db / 10.0) / bw;
  double noise_var = n0 * SAMPLE_RATE;          /* complex, per sample */
  float sigma = (float)sqrt(noise_var / 2.0);    /* per component */
  double duty = (double)spp / (double)(spp + gap);
  double total_rms = sqrt(duty * 1.0 + noise_var);
  float scale = (float)(32767.0 * pow(10.0, rms_dbfs / 20.0) / total_rms);
  fprintf(stderr, "snr_db=%.2f bw=%.0f noise_var=%.4g sigma=%.4g duty=%.3f scale=%.2f\n",
          snr_db, bw, noise_var, sigma, duty, scale);

  enum { CHUNK = 8192 };
  static int16_t out[2 * CHUNK];
  unsigned long long clipped = 0, written = 0;
  for (long k = 0;; k = (k + 1) % packets) {
    const float *p = tpl + (size_t)k * spp * 2;
    long total = spp + gap;
    for (long i = 0; i < total;) {
      int m = 0;
      for (; m < CHUNK && i < total; ++m, ++i) {
        float re = gauss() * sigma, im = gauss() * sigma;
        if (i < spp) { re += p[2 * i]; im += p[2 * i + 1]; }
        float a = re * scale, b = im * scale;
        if (a > 32767.f) { a = 32767.f; ++clipped; } else if (a < -32768.f) { a = -32768.f; ++clipped; }
        if (b > 32767.f) { b = 32767.f; ++clipped; } else if (b < -32768.f) { b = -32768.f; ++clipped; }
        out[2 * m] = (int16_t)lrintf(a);
        out[2 * m + 1] = (int16_t)lrintf(b);
      }
      if (fwrite(out, sizeof(int16_t), 2 * (size_t)m, stdout) != 2 * (size_t)m) {
        fprintf(stderr, "output closed after %llu samples, clipped %llu\n", written, clipped);
        return 0;
      }
      written += m;
    }
  }
}
