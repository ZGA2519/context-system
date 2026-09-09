"""python3 test_setup.py: install into a temp dir twice; files land, the re-run is a no-op."""
import json
import pathlib
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent


def run(*args):
    r = subprocess.run([sys.executable, HERE / "setup.py", *args], capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    return r.stdout


def test_install_twice():
    with tempfile.TemporaryDirectory() as tmp:
        t = pathlib.Path(tmp)
        out = run(t, "-y")
        assert (t / ".context/context_store/server.py").is_file()
        assert not (t / ".context/index.db").exists() and not (t / ".context/.venv").exists()
        assert (t / ".context/memories/main.jsonl").is_file()
        assert "context-system" in json.loads((t / ".mcp.json").read_text())["mcpServers"]
        assert (t / ".claude/hooks/context-sync.sh").is_file()
        assert "context-sync.sh" in (t / ".claude/settings.json").read_text()
        assert (t / ".agent/prompts/context-stop-sync.md").is_file()
        assert "0 unchanged" in out, out

        (t / ".context/memories/extra.jsonl").write_text("")
        out = run(t, "-y")
        assert "kept as is, 2 stores" in out and "already present" in out and "already registered" in out, out
        assert (t / ".context/memories/extra.jsonl").is_file()


def test_no_hook_and_refuses_checkout():
    with tempfile.TemporaryDirectory() as tmp:
        out = run(tmp, "-y", "--no-hook")
        assert "skipped (skill only)" in out and not (pathlib.Path(tmp) / ".claude/hooks").exists()
    r = subprocess.run([sys.executable, HERE / "setup.py", HERE, "-y"], capture_output=True, text=True)
    assert r.returncode == 1 and "source checkout" in r.stderr, r.stderr


def test_set_root_finds_repos_below_root():
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        near, deep, toodeep = root / "api", root / "a/b/web", root / "1/2/3/4/5/lost"
        for r in (near, deep, toodeep):
            r.mkdir(parents=True)
            run(r, "-y", "--no-hook")
        out = run(root, "--set-root", "-y")
        servers = json.loads((root / ".mcp.json").read_text())["mcpServers"]
        assert set(servers) == {"context-system-api", "context-system-web"}, servers
        reg = (root / ".claude/context-sync.repos").read_text().splitlines()
        assert len(reg) == 2 and str(near) in " ".join(reg) and str(deep) in " ".join(reg), reg
        assert (root / ".claude/skills/context-sync/SKILL.md").is_file()
        assert "lost" not in out


if __name__ == "__main__":
    test_install_twice()
    test_no_hook_and_refuses_checkout()
    test_set_root_finds_repos_below_root()
    print("ok")
