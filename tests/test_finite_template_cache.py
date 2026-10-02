from pathlib import Path
import sys
import pytest
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import finite_per_measure as finite

CACHE = '/tmp/lora-finite-cache-' + 'a'*32


@pytest.mark.parametrize('cached_match', [False, True])
def test_template_reuse_requires_matching_content_and_accounts_for_hardlink_memory(tmp_path, monkeypatch, cached_match):
    template = tmp_path / 'samples.c64'
    template.write_bytes(b'finite template bytes')
    expected = finite.sha256(template)
    commands, uploads = [], []
    def run(client, command):
        commands.append(command)
        if command.startswith('if [ -f '):
            return (expected if cached_match else '0'*64) + '  cached.c64\n'
        if command == 'df -k /tmp':
            return 'Filesystem 1K-blocks Used Available Use% Mounted on\ntmpfs 99999 0 32769 0% /tmp\n'
        if command.startswith('sha256sum '):
            return expected + '  uploaded.c64\n'
        return ''
    monkeypatch.setattr(finite.bench, 'run', run)
    monkeypatch.setattr(finite.bench, 'put', lambda c, local, remote: uploads.append((local, remote)))
    report = finite.stage_templates(None, template, '/tmp/lora-finite-point', CACHE)
    assert report['reused'] == cached_match and report['sha256'] == expected
    assert len(uploads) == (0 if cached_match else 1)
    assert (f'rm -f {CACHE}/templates.c64' in commands) != cached_match
    assert any(command.startswith('ln ') for command in commands)


def test_corrupt_upload_cannot_populate_template_cache(tmp_path, monkeypatch):
    template = tmp_path / 'samples.c64'; template.write_bytes(b'expected template')
    commands=[]
    def run(client, command):
        commands.append(command)
        if command == 'df -k /tmp': return 'tmpfs 999999 0 999999 0% /tmp\n'
        if command.startswith('sha256sum '): return '0'*64 + '  corrupted.c64\n'
        return ''
    monkeypatch.setattr(finite.bench, 'run', run)
    monkeypatch.setattr(finite.bench, 'put', lambda *args: None)
    with pytest.raises(RuntimeError, match='SHA256 differs'):
        finite.stage_templates(None, template, '/tmp/lora-finite-point', CACHE)
    assert not any(command.startswith('ln ') for command in commands)


def test_template_cache_cannot_target_arbitrary_paths(tmp_path, monkeypatch):
    template = tmp_path / 'samples.c64'; template.write_bytes(b'template')
    monkeypatch.setattr(finite.bench, 'run', lambda *args: pytest.fail('must reject before remote action'))
    with pytest.raises(ValueError): finite.stage_templates(None, template, '/tmp/point', '/tmp/../etc')


def test_cache_miss_checks_ram_before_upload(tmp_path, monkeypatch):
    template = tmp_path / 'samples.c64'; template.write_bytes(b'template')
    def run(client, command):
        return 'tmpfs 999 0 1 0% /tmp\n' if command == 'df -k /tmp' else ''
    monkeypatch.setattr(finite.bench, 'run', run)
    monkeypatch.setattr(finite.bench, 'put', lambda *args: pytest.fail('insufficient RAM must prevent upload'))
    with pytest.raises(RuntimeError, match='insufficient'):
        finite.stage_templates(None, template, '/tmp/lora-finite-point', CACHE)
