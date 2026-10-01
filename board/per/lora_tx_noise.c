/*
 * lora_tx_noise -- stream LoRa test packets with fresh AWGN to the AD9361 DAC.
 *
 * Runs on the CLG400 board and writes interleaved int16 I/Q to stdout, meant
 * to be piped into iio_writedev (non-cyclic, so every sample is new):
 *
 *   lora_tx_noise templates.iq <packets> <samples_per_packet> <gap_samples>
 *                 <snr_db_in_bw> <bw_hz> <rms_dbfs> [seed] [sample_rate]
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
 * sample_rate (default 1e6) is the rate the templates were made at. On this
 * board the DAC's rate depends on the RX side: with no RX DMA running it
 * takes 1 MS/s (the measuring case: the PL receiver and the SX126x/LR11xx
 * boards need no recording); while iio_readdev records, it takes one of our
 * samples per two 1 MS/s output slots and zero-fills the other (a +50 kHz tone
 * left as +25 kHz and an equal image at -475 kHz), so calibration recordings
 * are made with a 0.5 MS/s stream. SNR in the channel is the same either way:
 * signal and noise go through the same chain.
 *
 * SNR is defined in the signal bandwidth bw_hz: the noise is white over the
 * sample band with density N0 such that N0 * bw = 10^(-SNR/10)
 * (signal power 1). Output is scaled so that the stream's RMS sits at
 * rms_dbfs of int16 full scale; samples beyond full scale are clipped and
 * counted on stderr.
 */

#include <math.h>
#include <errno.h>
#include <limits.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>


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
static volatile sig_atomic_t stopped;
static void on_signal(int sig) { stopped = sig; }
static inline float gauss(void) {
  if (have_spare) { have_spare = 0; return spare; }
  float u, v, q;
  do { u = uni(); v = uni(); q = u * u + v * v; } while (q >= 1.0f || q == 0.0f);
  float m = sqrtf(-2.0f * logf(q) / q);
  spare = v * m; have_spare = 1;
  return u * m;
}

static long integer_arg(const char *text) {
  char *end;
  errno = 0;
  long value = strtol(text, &end, 10);
  if (errno || !*text || *end || value < 0) {
    fprintf(stderr, "invalid non-negative integer: %s\n", text);
    exit(2);
  }
  return value;
}

static double real_arg(const char *text) {
  char *end;
  errno = 0;
  double value = strtod(text, &end);
  if (errno || !*text || *end || !isfinite(value)) {
    fprintf(stderr, "invalid finite number: %s\n", text);
    exit(2);
  }
  return value;
}

static unsigned long long clipped, written;
static int emit(const float *p, long count, long signal_samples, float sigma, float scale) {
  enum { CHUNK = 8192 };
  static int16_t out[2 * CHUNK];
  for (long i = 0; i < count && !stopped;) {
    int m = 0;
    for (; m < CHUNK && i < count; ++m, ++i) {
      float re = gauss() * sigma, im = gauss() * sigma;
      if (i < signal_samples) { re += p[2 * i]; im += p[2 * i + 1]; }
      float a = re * scale, b = im * scale;
      if (a > 32767.f) { a = 32767.f; ++clipped; } else if (a < -32768.f) { a = -32768.f; ++clipped; }
      if (b > 32767.f) { b = 32767.f; ++clipped; } else if (b < -32768.f) { b = -32768.f; ++clipped; }
      out[2 * m] = (int16_t)lrintf(a);
      out[2 * m + 1] = (int16_t)lrintf(b);
    }
    if (fwrite(out, sizeof(int16_t), 2 * (size_t)m, stdout) != 2 * (size_t)m) return 1;
    written += m;
  }
  return stopped ? 1 : 0;
}

int main(int argc, char **argv) {
  if (argc < 8 || argc > 13) {
    fprintf(stderr, "usage: %s templates.iq packets samples_per_packet gap_samples snr_db bw_hz rms_dbfs [seed] [sample_rate] [limit_packets] [lead_samples] [tail_samples]\n", argv[0]);
    return 2;
  }
  const char *path = argv[1];
  long packets = integer_arg(argv[2]), spp = integer_arg(argv[3]), gap = integer_arg(argv[4]);
  double snr_db = real_arg(argv[5]), bw = real_arg(argv[6]), rms_dbfs = real_arg(argv[7]);
  uint32_t seed = argc > 8 ? (uint32_t)strtoul(argv[8], NULL, 0) : 1u;
  double sample_rate = argc > 9 ? real_arg(argv[9]) : 1e6;
  long limit = argc > 10 ? integer_arg(argv[10]) : 0;
  long lead = argc > 11 ? integer_arg(argv[11]) : 0;
  long tail = argc > 12 ? integer_arg(argv[12]) : 0;
  if (!packets || !spp || gap > LONG_MAX - spp || limit > packets ||
      spp > LONG_MAX / (2 * (long)sizeof(float)) ||
      !isfinite(snr_db) || !isfinite(bw) || !isfinite(rms_dbfs) ||
      !isfinite(sample_rate) || bw <= 0 || bw > sample_rate || sample_rate <= 0) {
    fprintf(stderr, "invalid dimensions or RF parameters (finite mode needs distinct templates)\n");
    return 2;
  }
  signal(SIGINT, on_signal);
  signal(SIGTERM, on_signal);
  signal(SIGPIPE, SIG_IGN);
  setvbuf(stdout, NULL, _IONBF, 0);
  s[0] = seed ^ 0x9E3779B9u; s[1] = 0x243F6A88u; s[2] = 0xB7E15162u ^ seed; s[3] = 0x7F4A7C15u;
  for (int i = 0; i < 16; ++i) next32();

  /* Read one template at a time, including long finite series on low-memory boards. */
  size_t n = (size_t)spp * 2;
  float *tpl = malloc(n * sizeof(float));
  FILE *f = fopen(path, "rb");
  if (!tpl || !f) { fprintf(stderr, "cannot open %s\n", path); free(tpl); if (f) fclose(f); return 1; }

  /* Noise per real component: total complex variance N0 * fs. */
  double n0 = pow(10.0, -snr_db / 10.0) / bw;
  double noise_var = n0 * sample_rate;          /* complex, per sample */
  float sigma = (float)sqrt(noise_var / 2.0);    /* per component */
  double duty = (double)spp / (double)(spp + gap);
  double total_rms = sqrt(duty * 1.0 + noise_var);
  float scale = (float)(32767.0 * pow(10.0, rms_dbfs / 20.0) / total_rms);
  if (!isfinite(sigma) || !isfinite(scale) || total_rms == 0) {
    fprintf(stderr, "noise/scale exceeds numeric range\n"); fclose(f); free(tpl); return 2;
  }
  fprintf(stderr, "snr_db=%.2f bw=%.0f fs=%.0f noise_var=%.4g sigma=%.4g duty=%.3f scale=%.2f\n",
          snr_db, bw, sample_rate, noise_var, sigma, duty, scale);

  long completed = 0;
  int failed = emit(NULL, lead, 0, sigma, scale);
  for (long k = 0; !failed && !stopped && (!limit || completed < limit); k = (k + 1) % packets) {
    if (k == 0) rewind(f);
    if (fread(tpl, sizeof(float), n, f) != n) { fprintf(stderr, "short template %ld\n", k); failed = 1; break; }
    failed = emit(tpl, spp + gap, spp, sigma, scale);
    if (!failed) ++completed;
  }
  if (!failed && !stopped) failed = emit(NULL, tail, 0, sigma, scale);
  /* iio_writedev 0.25 drops an incomplete final buffer. Pad with noise to its
   * 262144-sample buffer, with the whole final packet already inside the tail. */
  if (limit && !failed && !stopped)
    failed = emit(NULL, (long)((262144 - written % 262144) % 262144), 0, sigma, scale);
  fprintf(stderr, "TX_SUMMARY packets_completed=%ld samples_written=%llu clipped_components=%llu finite=%d complete=%d signal=%d\n",
          completed, written, clipped, limit != 0, !failed && !stopped && limit != 0, (int)stopped);
  fclose(f);
  free(tpl);
  return failed || stopped ? 1 : 0;
}
