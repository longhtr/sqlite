#!/usr/bin/env python3
"""Verify every repository script has a purpose and uses fail-closed subprocesses."""

from __future__ import annotations

import ast
from dataclasses import replace
import os
import pathlib
import shutil
import sys
import tempfile
import time

import bounded_subprocess as subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent
TOOLS = ROOT / "tools"
LIBRARIES = {
    "bounded_subprocess.py": "central resource-contained process execution",
    "port_batch_gate.py": "canonical direct-tool translation-batch gate",
}
SPECIAL_ENTRYPOINTS = {
    "ci_quick.py": "manual and build-exposed three-mode CI driver",
    "compatibility_report.py": "honest machine-readable incomplete-port report",
    "differential_probe.py": "baseline metadata differential",
    "make_hybrid_parser.py": "test-only hybrid parser source transform",
    "native_c_audit.py": "zero-C production artifact audit",
    "port_audit.py": "authoritative machine-readable project status generator",
    "run_bounded.py": "build-system adapter for central resource-contained execution",
}


def category(path: pathlib.Path) -> str | None:
    name = path.name
    if name in LIBRARIES:
        return LIBRARIES[name]
    if name in SPECIAL_ENTRYPOINTS:
        return SPECIAL_ENTRYPOINTS[name]
    if name.startswith("generate_"):
        return "deterministic generated-artifact producer/verifier"
    if name.endswith("_differential.py"):
        return "bounded C-oracle/Zig differential"
    if name.startswith("verify_"):
        return "repository invariant verification gate"
    if name.startswith("test_"):
        return "explicit assurance driver"
    return None


def has_main_guard(module: ast.Module) -> bool:
    for node in module.body:
        if isinstance(node, ast.If) and isinstance(node.test, ast.Compare):
            if ast.unparse(node.test) == "__name__ == '__main__'":
                return True
    return False


def verify_static() -> int:
    scripts = sorted(TOOLS.glob("*.py"))
    reference_paths = [ROOT / "build.zig", ROOT / "README.md"]
    reference_paths += list((ROOT / "tools").glob("*.py"))
    reference_paths += list((ROOT / "docs").rglob("*.md"))
    failures: list[str] = []
    for path in scripts:
        module = ast.parse(path.read_text(), filename=str(path))
        purpose = ast.get_docstring(module)
        if purpose is None or len(purpose.strip()) < 20:
            failures.append(f"{path.relative_to(ROOT)} lacks a meaningful module purpose")
        if category(path) is None:
            failures.append(f"{path.relative_to(ROOT)} has no tooling category")
        if path.name not in LIBRARIES and not has_main_guard(module):
            failures.append(f"{path.relative_to(ROOT)} lacks an explicit main guard")
        if path.name not in LIBRARIES and "require_ready()" not in path.read_text():
            failures.append(f"{path.relative_to(ROOT)} bypasses the active translation-batch gate")
        for node in ast.walk(module):
            if isinstance(node, ast.Import):
                for alias in node.names:
                    if alias.name == "subprocess" and path.name != "bounded_subprocess.py":
                        failures.append(f"{path.relative_to(ROOT)} imports unbounded stdlib subprocess")
            if isinstance(node, ast.ImportFrom) and node.module == "subprocess":
                failures.append(f"{path.relative_to(ROOT)} imports unbounded stdlib subprocess")
            if (
                path.name != "bounded_subprocess.py"
                and isinstance(node, ast.Call)
                and isinstance(node.func, ast.Attribute)
                and isinstance(node.func.value, ast.Name)
                and node.func.value.id == "os"
                and node.func.attr in {"system", "popen", "spawnl", "spawnle", "spawnlp", "spawnlpe", "spawnv", "spawnve", "spawnvp", "spawnvpe"}
            ):
                failures.append(f"{path.relative_to(ROOT)} calls unbounded os.{node.func.attr}")
        if path.name not in LIBRARIES:
            references = sum(
                candidate.read_text(errors="replace").count(path.name)
                for candidate in reference_paths
                if candidate != path
            )
            if references < 1:
                failures.append(f"{path.relative_to(ROOT)} is an orphan entrypoint")
    build_source = (ROOT / "build.zig").read_text()
    if build_source.count("b.addSystemCommand(") != 2:
        failures.append("build.zig has a direct system command outside the two bounded adapters")
    if "b.addRunArtifact(" in build_source:
        failures.append("build.zig has a direct unbounded run artifact")
    if "tools/run_bounded.py" not in build_source:
        failures.append("build.zig does not route commands through tools/run_bounded.py")

    shell_scripts = sorted(TOOLS.glob("*.sh"))
    if shell_scripts:
        failures.append(
            "shell entrypoints bypass the central process runner: "
            + ", ".join(str(path.relative_to(ROOT)) for path in shell_scripts)
        )
    if failures:
        raise SystemExit("tooling audit failed:\n- " + "\n- ".join(failures))
    return len(scripts)


def expect_failure(command: list[str], limits: subprocess.Limits, kind: str) -> pathlib.Path:
    try:
        subprocess.run(
            command,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            limits=limits,
        )
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        artifact = pathlib.Path(getattr(error, "artifact_path", ""))
        if not artifact.is_dir() or not (artifact / "metadata.json").is_file():
            raise SystemExit(f"{kind}: bounded failure did not preserve metadata") from error
        return artifact
    raise SystemExit(f"{kind}: expected bounded child failure")


def process_exists(pid: int) -> bool:
    try:
        stat = pathlib.Path(f"/proc/{pid}/stat").read_text()
    except OSError:
        return False
    state = stat[stat.rfind(")") + 2 :].split()[0]
    return state != "Z"


def verify_runtime() -> None:
    artifacts: list[pathlib.Path] = []
    python = sys.executable
    try:
        success = subprocess.check_output([python, "-c", "print('contained')"], text=True)
        if success != "contained\n":
            raise SystemExit("bounded success output mismatch")
        # Exercise the /proc RSS scanner against rapidly exiting processes. A
        # process may disappear between directory enumeration and stat reads.
        for _ in range(32):
            subprocess.run([python, "-c", "pass"], check=True)

        tiny_output = replace(
            subprocess.WORKER_LIMITS,
            timeout_seconds=5,
            output_bytes=1_024,
            file_bytes=4_096,
        )
        artifacts.append(expect_failure(
            [python, "-c", "import os; os.write(1, b'x'*65536)"],
            tiny_output,
            "output limit",
        ))

        timeout_limits = replace(subprocess.WORKER_LIMITS, timeout_seconds=0.2)
        try:
            subprocess.run(
                [
                    python,
                    "-c",
                    "import subprocess,sys,time; "
                    "p=subprocess.Popen([sys.executable,'-c','import time;time.sleep(60)']); "
                    "print(p.pid,flush=True);time.sleep(60)",
                ],
                check=True,
                stdout=subprocess.PIPE,
                limits=timeout_limits,
            )
        except subprocess.TimeoutExpired as error:
            artifact = pathlib.Path(getattr(error, "artifact_path", ""))
            artifacts.append(artifact)
            output = error.output.decode() if isinstance(error.output, bytes) else error.output
            child_pid = int((output or "").strip())
            for _ in range(20):
                if not process_exists(child_pid):
                    break
                time.sleep(0.05)
            else:
                raise SystemExit(f"timeout failed to kill process-group child {child_pid}")
        else:
            raise SystemExit("timeout limit did not fail")

        rss_limits = replace(
            subprocess.WORKER_LIMITS,
            timeout_seconds=5,
            address_space_bytes=512 << 20,
            rss_bytes=48 << 20,
        )
        artifacts.append(expect_failure(
            [python, "-c", "import time;x=bytearray(256*1024*1024);print(len(x));time.sleep(2)"],
            rss_limits,
            "RSS limit",
        ))

        with tempfile.TemporaryDirectory(prefix="sqlite-zig-file-limit-") as temporary:
            file_limits = replace(
                subprocess.WORKER_LIMITS,
                timeout_seconds=5,
                file_bytes=1 << 20,
            )
            large = pathlib.Path(temporary) / "large"
            artifacts.append(expect_failure(
                [python, "-c", f"open({str(large)!r},'wb').write(b'x'*(4*1024*1024))"],
                file_limits,
                "file-size limit",
            ))
    finally:
        for artifact in artifacts:
            shutil.rmtree(artifact, ignore_errors=True)


def main() -> None:
    scripts = verify_static()
    verify_runtime()
    print(f"verify-tooling: {scripts} purposeful Python scripts use bounded child execution")


if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
