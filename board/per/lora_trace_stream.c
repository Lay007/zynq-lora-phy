/*
 * lora_trace_stream -- read the PL symbol trace packet after packet, fast.
 *
 * Runs on the CLG400 board (Buildroot, armv7l, static binary). Maps the gpreg
 * bridge through /dev/mem and loops:
 *
 *   re-arm the trace (CONTROL bit 2, trace_rearm; bit 3, the decision-history
 *   freeze, is cleared too) -> wait until the symbol trace completes -> read
 *   its 128 entries, page 0 (the published timestamp) and the joint status ->
 *   print one line -> re-arm.
 *
 * Nothing here decodes: the host runs the same packet decoder as every other
 * tool (tools/per_stream_host.py). What this saves is the SSH round trip per
 * register: a devmem shell loop needs about a second per trace, this reads one
 * in well under a millisecond, so the trace is re-armed long before the next
 * packet of a test stream.
 *
 * Output, one line per captured packet:
 *
 *   PKT <t_ms> cap=<capture_sequence> pbin=<preamble_bin> realigned=<0|1>
 *       n=<captured_count> p0seq=<page0 sequence> p0coarse=<hex64>
 *       p0frac=<q12> joint=<hex> sym=<hex byte per symbol, 128 x 2 chars>
 *   TIMEOUT <t_ms> status=<hex>       (no complete trace within --timeout-ms)
 *
 * Register map and page selection as tools/read_clg400_symbol_trace.py.
 *
 *   lora_trace_stream [count] [timeout_ms]      (count 0 = forever)
 */

#include <fcntl.h>
#include <inttypes.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define BRIDGE_BASE 0x79040000u
#define REG(off) (*(volatile uint32_t *)((volatile uint8_t *)regs + (off)))
#define CONTROL 0x404
#define STATUS 0x408
#define SEQUENCE 0x448
#define SYMBOL 0x488
#define SAMPLE_LO 0x4c8
#define SAMPLE_HI 0x508
#define METRICS 0x548
#define DEBUG 0x588
#define SIGNATURE 0x5c8

#define PAGE_MASK 0x80f8ffffu /* keeps everything but the page/index bits */
#define SYMBOL_PAGE 0x00010000u
#define JOINT_PAGE 0x00040000u
#define TRACE_DEPTH 128

static volatile uint32_t *regs;
static volatile int stop;
static uint32_t control_base;

static void on_signal(int sig) { (void)sig; stop = 1; }

static uint64_t now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000u + (uint64_t)ts.tv_nsec / 1000000u;
}

static void sleep_us(long us) {
  struct timespec ts = {us / 1000000, (us % 1000000) * 1000};
  nanosleep(&ts, NULL);
}

/* Select a page; a read of STATUS afterwards orders the write before the
 * data reads (the bridge registers the selected entry one ctrl clock later). */
static void select_page(uint32_t page_bits) {
  REG(CONTROL) = (control_base & PAGE_MASK) | page_bits;
  (void)REG(STATUS);
  (void)REG(STATUS);
}

static void rearm(void) {
  uint32_t run = control_base & ~(0x4u | 0x8u); /* rearm low, freeze released */
  REG(CONTROL) = run | 0x4u;
  sleep_us(2000);
  REG(CONTROL) = run;
  control_base = run;
}

int main(int argc, char **argv) {
  long count = argc > 1 ? atol(argv[1]) : 0;
  long timeout_ms = argc > 2 ? atol(argv[2]) : 5000;
  int fd = open("/dev/mem", O_RDWR | O_SYNC);
  if (fd < 0) { perror("/dev/mem"); return 1; }
  regs = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, BRIDGE_BASE);
  if (regs == MAP_FAILED) { perror("mmap"); return 1; }
  if (REG(SIGNATURE) != 0x4C4F5241u) {
    fprintf(stderr, "unexpected bridge signature 0x%08x\n", REG(SIGNATURE));
    return 1;
  }
  signal(SIGINT, on_signal);
  signal(SIGTERM, on_signal);
  setvbuf(stdout, NULL, _IOLBF, 0);
  control_base = REG(CONTROL);
  uint32_t original = control_base;
  uint64_t t0 = now_ms();
  printf("START bridge=LORA control=0x%08x count=%ld timeout_ms=%ld\n", original, count, timeout_ms);

  for (long got = 0; !stop && (count == 0 || got < count);) {
    rearm();
    select_page(SYMBOL_PAGE);
    uint64_t start = now_ms();
    uint32_t status = 0;
    for (;;) {
      status = REG(STATUS);
      if ((status >> 16) == 0x5359u && (status & 0x200u) && !(status & 0x100u)) break;
      if (stop || now_ms() - start > (uint64_t)timeout_ms) break;
      sleep_us(500);
    }
    if (stop) break;
    if (!((status & 0x200u) && !(status & 0x100u))) {
      printf("TIMEOUT %" PRIu64 " status=0x%08x\n", now_ms() - t0, status);
      ++got; /* a timeout is an attempt too, so a dead receiver cannot hang the run */
      continue;
    }
    unsigned captured = status & 0xffu;
    uint32_t sequence = REG(SEQUENCE);
    uint32_t debug = REG(DEBUG);
    char sym[2 * TRACE_DEPTH + 1];
    int changed = 0;
    for (unsigned i = 0; i < TRACE_DEPTH; ++i) {
      select_page(SYMBOL_PAGE | (i << 24));
      uint32_t s = REG(SYMBOL);
      if (REG(STATUS) != status || REG(SEQUENCE) != sequence) changed = 1;
      snprintf(&sym[2 * i], 3, "%02x", s & 0xffu);
    }
    select_page(0); /* page 0: the published timestamp */
    uint32_t p0seq = REG(SEQUENCE);
    uint32_t p0lo = REG(SYMBOL);
    uint32_t p0hi = REG(SAMPLE_LO);
    int32_t p0frac = (int32_t)REG(SAMPLE_HI);
    select_page(JOINT_PAGE);
    uint32_t joint = REG(STATUS);
    select_page(0);
    printf("PKT %" PRIu64 " cap=%u pbin=%u realigned=%u n=%u p0seq=%u p0coarse=0x%08x%08x "
           "p0frac=%d joint=0x%08x changed=%d sym=%s\n",
           now_ms() - t0, sequence, debug >> 16, (debug >> 8) & 1u, captured, p0seq,
           p0hi, p0lo, p0frac, joint, changed, sym);
    ++got;
  }
  REG(CONTROL) = original & ~0x4u;
  printf("STOP\n");
  return 0;
}
