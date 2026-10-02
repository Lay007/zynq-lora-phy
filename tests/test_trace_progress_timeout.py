"""Exercise the actual C wait policy at the startup deadline and on stalls."""
import shutil
import subprocess
from pathlib import Path

import pytest


def test_capture_progress_survives_deadline_and_stalls_still_timeout(tmp_path):
    cc = shutil.which("gcc")
    if not cc:
        pytest.skip("native GCC required for board C regression")
    source = Path(__file__).resolve().parents[1] / "board/per/lora_trace_stream.c"
    driver = tmp_path / "timeout.c"
    driver.write_text(
        '#define main trace_stream_main\n'
        f'#include "{source.as_posix()}"\n'
        '#undef main\n#include <assert.h>\n'
        'int main(void) {\n'
        '  struct trace_wait idle = {220, 0};\n'
        '  assert(!trace_wait_expired(&idle, 1220, 1000, 0x53590000));\n'
        '  assert(trace_wait_expired(&idle, 1223, 1000, 0x53590000));\n'
        '  struct trace_wait live = {220, 0};\n'
        '  assert(!trace_wait_expired(&live, 1210, 1000, 0x53590101));\n'
        '  /* Original SF5 timeout: capture active, already 68 symbols. */\n'
        '  assert(!trace_wait_expired(&live, 1223, 1000, 0x53590144));\n'
        '  assert(!trace_wait_expired(&live, 1227, 1000, 0x5359017f));\n'
        '  assert(!trace_wait_expired(&live, 2227, 1000, 0x5359017f));\n'
        '  assert(trace_wait_expired(&live, 2228, 1000, 0x5359017f));\n'
        '  /* Active-with-zero-count earns one interval, not infinite waits. */\n'
        '  struct trace_wait stalled = {0, 0};\n'
        '  assert(!trace_wait_expired(&stalled, 999, 1000, 0x53590100));\n'
        '  assert(trace_wait_expired(&stalled, 2000, 1000, 0x53590100));\n'
        '  /* Idle timeout must not pulse reset over a just-starting frame. */\n'
        '  assert(!trace_timeout_needs_rearm(0x53590000));\n'
        '  assert(trace_timeout_needs_rearm(0x53590100));\n'
        '  assert(trace_timeout_needs_rearm(0x53590144));\n'
        '  return 0;\n}\n', encoding="utf-8")
    binary = tmp_path / "timeout"
    subprocess.run([cc, "-O2", "-Wall", "-Wextra", "-Werror",
                    str(driver), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)


def test_real_collector_loop_does_not_rearm_after_idle_timeouts(tmp_path):
    cc = shutil.which("gcc")
    if not cc:
        pytest.skip("native GCC required for board C regression")
    source = Path(__file__).resolve().parents[1] / "board/per/lora_trace_stream.c"
    driver = tmp_path / "idle.c"
    driver.write_text(
        '#include <fcntl.h>\n#include <stdint.h>\n#include <sys/mman.h>\n'
        '#include <time.h>\n#include <unistd.h>\n#include <assert.h>\n'
        'static uint32_t bank[1024];\nstatic unsigned rearm_pulses;\n'
        'static uint64_t simulated_ms;\n'
        'static int fake_open(const char *p, int flags, ...) { (void)p; (void)flags; return 1; }\n'
        'static void *fake_mmap(void *p, size_t n, int prot, int flags, int fd, off_t off) {\n'
        '  (void)p; (void)n; (void)prot; (void)flags; (void)fd; (void)off;\n'
        '  bank[0x5c8/4]=0x4c4f5241; bank[0x404/4]=0x1201; return bank; }\n'
        'static int fake_sleep(const struct timespec *req, struct timespec *rem) {\n'
        '  (void)rem; simulated_ms += req->tv_nsec/1000000;\n'
        '  if (bank[0x404/4]&4) ++rearm_pulses;\n  return 0; }\n'
        'static int fake_clock(clockid_t id, struct timespec *ts) {\n'
        '  (void)id; ++simulated_ms; ts->tv_sec=simulated_ms/1000;\n'
        '  ts->tv_nsec=(simulated_ms%1000)*1000000;\n'
        '  bank[0x408/4]=(bank[0x404/4]&0x10000)?0x53590000:0; return 0; }\n'
        '#define open fake_open\n#define mmap fake_mmap\n'
        '#define nanosleep fake_sleep\n#define clock_gettime fake_clock\n'
        '#define main trace_stream_main\n'
        f'#include "{source.as_posix()}"\n'
        '#undef main\n'
        'int main(void) {\n'
        '  char *args[]={"trace", "3", "2", "0", "7", "8", "128"};\n'
        '  assert(trace_stream_main(7,args)==0);\n'
        '  assert(rearm_pulses==1);\n'
        '  assert((bank[0x404/4]&4)==0); return 0;\n}\n', encoding="utf-8")
    binary = tmp_path / "idle"
    subprocess.run([cc, "-O2", "-Wall", "-Wextra", "-Werror",
                    str(driver), "-o", str(binary)], check=True)
    run = subprocess.run([str(binary)], check=True, capture_output=True, text=True)
    assert run.stdout.count("TIMEOUT ") == 3
