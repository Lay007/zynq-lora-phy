"""Generated HDL snapshots must not carry the generating machine's absolute paths.

HDL Coder writes its output directory into every file header; tools/normalize_generated_hdl.py
rewrites those to repository-relative paths. This keeps the check in CI so a new snapshot committed
without normalization fails here instead of leaking a local directory layout.
"""

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_generated_hdl_has_no_absolute_paths() -> None:
    result = subprocess.run([sys.executable, str(ROOT / "tools" / "normalize_generated_hdl.py"), "--check"],
                            capture_output=True, text=True, cwd=ROOT)
    assert result.returncode == 0, "absolute paths in generated HDL:\n" + result.stdout


def test_normalize_rewrites_windows_and_posix_prefixes() -> None:
    sys.path.insert(0, str(ROOT / "tools"))
    from normalize_generated_hdl import normalize_text

    win = r"// File Name: C:\build\out\sfd\lora_sfd_gen\lora_sfd_DUT.v"
    assert normalize_text(win, "sfd") == "// File Name: fpga/generated/sfd/lora_sfd_gen/lora_sfd_DUT.v"
    esc = r'"dir": "D:\\work\\gen\\sfd\\lora_sfd_gen"'
    assert normalize_text(esc, "sfd") == '"dir": "fpga/generated/sfd/lora_sfd_gen"'
    posix = "// File Name: /home/builder/gen/sfd/lora_sfd_gen/a.v"
    assert normalize_text(posix, "sfd") == "// File Name: fpga/generated/sfd/lora_sfd_gen/a.v"
