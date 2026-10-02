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
