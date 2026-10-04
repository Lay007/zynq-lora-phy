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
 *       p0frac=<q12> joint=<hex> sf=<5..12> sym_bits=<8|16>
 *       sym=<128 slots of 2 hex chars for SF<=8, otherwise 4; unused slots zero>
 *   TIMEOUT <t_ms> status=<hex>       (no capture progress within timeout_ms)
 *
 * Register map and page selection as tools/read_clg400_symbol_trace.py.
 *
 *   lora_trace_stream [count] [timeout_ms] [duration_ms] [SF] [L] [entries]
 *   count/duration 0 = unlimited; defaults SF7, L8, 128 entries.
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

#define PAGE_MASK 0x80f8ff4fu /* keeps capture limit; clears history/profile/latency/page/index bits */
#define SYMBOL_PAGE 0x00010000u
#define JOINT_PAGE 0x00040000u
#define CLOCK_PAGE 0x00020000u
#define TRACE_DEPTH 128
#define PROFILE_PAGE 0x20u
#define LATENCY_PAGE 0x80u
#define TRACE_LIMIT_MASK 0x80f80000u
#define TRACE_LIMIT_ENABLE 0x40u

static volatile uint32_t *regs;
static volatile sig_atomic_t stop;
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

struct trace_wait {
  uint64_t last_progress_ms;
  uint32_t capture_state;
};

/* A deadline from rearm can bisect the first frame after the TX lead-in.
 * Observe both the active flag and symbol count: a live capture earns a full
 * inactivity interval, but a stalled capture still times out. A bounded trace
 * has at most 128 count increments; duration_ms remains an absolute run limit. */
static int trace_wait_expired(struct trace_wait *wait, uint64_t now,
                              uint64_t timeout_ms, uint32_t status) {
  uint32_t state = status & 0x1ffu;
  if (state != wait->capture_state) {
    wait->capture_state = state;
    wait->last_progress_ms = now;
  }
  return now - wait->last_progress_ms > timeout_ms;
}

static int trace_timeout_needs_rearm(uint32_t status) {
  /* Empty/inactive means it is already armed. Pulsing rearm here creates a
   * blind interval and can also clear acquisition immediately before capture. */
  return (status & 0x1ffu) != 0;
}

int main(int argc, char **argv) {
  long count = argc > 1 ? atol(argv[1]) : 0;
  long timeout_ms = argc > 2 ? atol(argv[2]) : 5000;
  long duration_ms = argc > 3 ? atol(argv[3]) : 0;
  unsigned sf = argc > 4 ? (unsigned)atoi(argv[4]) : 7u;
  unsigned spc = argc > 5 ? (unsigned)atoi(argv[5]) : 8u;
  unsigned entries = argc > 6 ? (unsigned)atoi(argv[6]) : TRACE_DEPTH;
  if (count < 0 || timeout_ms <= 0 || duration_ms < 0 || sf < 5 || sf > 12 ||
      (spc != 2 && spc != 4 && spc != 8) || entries < 2 || entries > 128 || (entries & 1u)) return 2;
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
  select_page(PROFILE_PAGE);
  uint32_t profile = REG(STATUS);
  int wideband_abi = (profile >> 16) == 0x5742u;
  if ((wideband_abi && ((profile >> 8 & 0xffu) != sf || (profile & 0xffu) != spc)) ||
      (!wideband_abi && (sf != 7 || spc != 8 || entries != TRACE_DEPTH))) {
    REG(CONTROL) = original;
    fprintf(stderr, "receiver build profile mismatch: profile=0x%08x requested SF%u L%u n=%u\n", profile, sf, spc, entries);
    return 1;
  }
  if (wideband_abi) {
    unsigned pairs = entries == TRACE_DEPTH ? 0u : entries / 2u;
    control_base = (control_base & ~TRACE_LIMIT_MASK) | TRACE_LIMIT_ENABLE |
                   ((pairs & 31u) << 19) | ((pairs >> 5) << 31);
  }
  uint64_t t0 = now_ms();
  printf("START bridge=LORA control=0x%08x count=%ld timeout_ms=%ld\n", original, count, timeout_ms);
  select_page(0);
  uint32_t last_p0seq = REG(SEQUENCE);
  int needs_rearm = 1;

  for (long got = 0; !stop && (count == 0 || got < count);) {
    if (duration_ms && now_ms() - t0 >= (uint64_t)duration_ms) break;
    if (needs_rearm) rearm();
    needs_rearm = 0;
    select_page(CLOCK_PAGE);
    uint32_t drop_before = REG(METRICS) & 0xffffu;
    select_page(SYMBOL_PAGE);
    if (got == 0) printf("READY %" PRIu64 "\n", now_ms() - t0);
    struct trace_wait wait = {now_ms(), 0};
    uint32_t status = 0;
    for (;;) {
      status = REG(STATUS);
      if ((status >> 16) == 0x5359u && (status & 0x200u) && !(status & 0x100u)) break;
      if (stop || trace_wait_expired(&wait, now_ms(), (uint64_t)timeout_ms, status)) break;
      if (duration_ms && now_ms() - t0 >= (uint64_t)duration_ms) break;
      sleep_us(500);
    }
    if (stop) break;
    if (duration_ms && now_ms() - t0 >= (uint64_t)duration_ms) break;
    if (!((status & 0x200u) && !(status & 0x100u))) {
      /* Retain sticky acquisition outcomes even without a complete packet,
       * including accumulated-preamble triggers on noise-only campaigns. */
      select_page(JOINT_PAGE);
      uint32_t timeout_joint = REG(STATUS);
      select_page(CLOCK_PAGE);
      uint32_t timeout_clock = REG(STATUS);
      uint32_t timeout_drop = REG(METRICS) & 0xffffu;
      printf("TIMEOUT %" PRIu64 " status=0x%08x joint=0x%08x clock_status=0x%08x drop_before=%u drop_after=%u\n",
             now_ms() - t0, status, timeout_joint, timeout_clock, drop_before, timeout_drop);
      ++got; /* a timeout is an attempt too, so a dead receiver cannot hang the run */
      needs_rearm = trace_timeout_needs_rearm(status);
      continue;
    }
    unsigned captured = status & 0xffu;
    if (captured != entries) {
      REG(CONTROL) = original;
      fprintf(stderr, "unexpected trace length: %u, requested %u\n", captured, entries);
      return 1;
    }
    uint32_t sequence = REG(SEQUENCE);
    uint32_t debug = REG(DEBUG);
    unsigned digits = sf > 8 ? 4u : 2u;
    char sym[4 * TRACE_DEPTH + 1];
    /* Fixed host framing: unused tail entries are zero, not stale RAM. */
    for (unsigned i = 0; i < digits * TRACE_DEPTH; ++i) sym[i] = '0';
    sym[digits * TRACE_DEPTH] = '\0';
    int changed = 0;
    for (unsigned i = 0; i < captured; ++i) {
      select_page(SYMBOL_PAGE | (i << 24));
      uint32_t s = REG(SYMBOL);
      if (REG(STATUS) != status || REG(SEQUENCE) != sequence) changed = 1;
      if (sf > 8) snprintf(&sym[digits*i], 5, "%04x", s & 0xffffu);
      else snprintf(&sym[digits*i], 3, "%02x", s & 0xffu);
    }
    if (captured < TRACE_DEPTH) sym[digits*captured] = '0';
    select_page(0); /* page 0: the published timestamp */
    uint32_t p0seq = REG(SEQUENCE);
    uint32_t p0status = REG(STATUS);
    uint32_t p0lo = REG(SYMBOL);
    uint32_t p0hi = REG(SAMPLE_LO);
    int32_t p0frac = (int32_t)REG(SAMPLE_HI);
    uint32_t p0log = REG(METRICS);
    uint32_t p0debug = REG(DEBUG);
    if (p0seq != REG(SEQUENCE)) changed = 1;
    select_page(JOINT_PAGE);
    uint32_t joint = REG(STATUS);
    int32_t joint_correction = (int32_t)REG(SEQUENCE);
    int32_t joint_up_offset = (int32_t)REG(SYMBOL);
    uint32_t joint_up_coarse = REG(SAMPLE_LO);
    uint32_t joint_packet_start = REG(SAMPLE_HI);
    uint32_t joint_phase_bin = REG(METRICS);
    select_page(CLOCK_PAGE);
    uint32_t clock_status = REG(STATUS);
    uint32_t sample_interval_clocks = REG(SEQUENCE);
    uint32_t mac_search_clocks = REG(SYMBOL);
    uint32_t sample_interval_min_clocks = REG(SAMPLE_LO);
    uint32_t mac_search_completed = REG(SAMPLE_HI);
    uint32_t drop_after = REG(METRICS) & 0xffffu;
    /* LT1 has the same held payload/sequence as page 0. Old images return
     * another page here; preserve its status so the host reports unsupported. */
    select_page(LATENCY_PAGE);
    uint32_t lat_status = REG(STATUS);
    uint32_t lat_seq = REG(SEQUENCE);
    uint32_t lat_detect_clocks = REG(SYMBOL);
    uint32_t lat_down_clocks = REG(SAMPLE_LO);
    uint32_t lat_lo = REG(SAMPLE_HI);
    uint32_t lat_hi = REG(METRICS);
    int32_t lat_frac = (int32_t)REG(DEBUG);
    int lat_changed = lat_seq != REG(SEQUENCE) || lat_status != REG(STATUS);
    if ((lat_status >> 8) == 0x4c5401u &&
        (lat_seq != p0seq || lat_lo != p0lo || lat_hi != p0hi || lat_frac != p0frac))
      lat_changed = 1;
    select_page(0);
    if (p0seq != REG(SEQUENCE)) changed = 1;
    printf("PKT %" PRIu64 " cap=%u pbin=%u realigned=%u n=%u p0seq=%u p0coarse=0x%08x%08x "
           "p0frac=%d p0status=0x%08x p0log=%d p0debug=0x%08x joint=0x%08x joint_correction=%d joint_up_offset=%d joint_up_coarse=%u joint_packet_start=%u joint_phase_bin=0x%08x clock_status=0x%08x drop_before=%u drop_after=%u p0fresh=%d changed=%d sf=%u sym_bits=%u sample_interval_clocks=%u sample_interval_min_clocks=%u mac_search_clocks=%u mac_search_completed=%u lat_status=0x%08x lat_seq=%u lat_detect_clocks=%u lat_down_clocks=%u lat_coarse=0x%08x%08x lat_frac=%d lat_changed=%d sym=%s\n",
           now_ms() - t0, sequence, debug >> 16, (debug >> 8) & 1u, captured, p0seq,
           p0hi, p0lo, p0frac, p0status, (int32_t)p0log, p0debug, joint,
           joint_correction, joint_up_offset, joint_up_coarse, joint_packet_start, joint_phase_bin, clock_status,
           drop_before, drop_after, p0seq != last_p0seq, changed, sf, digits*4u,
           sample_interval_clocks, sample_interval_min_clocks, mac_search_clocks, mac_search_completed,
           lat_status, lat_seq, lat_detect_clocks, lat_down_clocks, lat_hi, lat_lo, lat_frac, lat_changed, sym);
    last_p0seq = p0seq;
    needs_rearm = 1;
    ++got;
  }
  REG(CONTROL) = original & ~0x4u;
  printf("STOP\n");
  return 0;
}
