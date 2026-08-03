#!/usr/bin/env python3
"""Fail-closed subprocess execution for repository tools and test workers.

Child output is written to bounded regular files rather than buffered through
pipes. Failures preserve command metadata and output under .test-artifacts/.
This module intentionally exposes the small subprocess API subset used by the
repository so scripts can import it as ``subprocess``.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass, replace
import json
import os
from pathlib import Path
import resource
import shutil
import signal
import subprocess as _subprocess
import sys
import time
from typing import IO, Mapping, Sequence

ROOT = Path(__file__).resolve().parent.parent
ARTIFACT_ROOT = ROOT / ".test-artifacts/subprocess"

PIPE = _subprocess.PIPE
STDOUT = _subprocess.STDOUT
DEVNULL = _subprocess.DEVNULL
CalledProcessError = _subprocess.CalledProcessError
TimeoutExpired = _subprocess.TimeoutExpired
CompletedProcess = _subprocess.CompletedProcess


@dataclass(frozen=True)
class Limits:
    timeout_seconds: float
    output_bytes: int
    address_space_bytes: int
    rss_bytes: int
    file_bytes: int
    open_files: int
    processes: int
    cpu_seconds: int
    argument_count: int
    argument_bytes: int
    input_bytes: int


WORKER_LIMITS = Limits(
    timeout_seconds=30,
    output_bytes=4 << 20,
    address_space_bytes=2 << 30,
    rss_bytes=1 << 30,
    file_bytes=64 << 20,
    open_files=128,
    processes=2_048,
    cpu_seconds=30,
    argument_count=20_000,
    argument_bytes=4 << 20,
    input_bytes=8 << 20,
)
TOOL_LIMITS = Limits(
    timeout_seconds=300,
    output_bytes=16 << 20,
    address_space_bytes=4 << 30,
    rss_bytes=3 << 30,
    file_bytes=512 << 20,
    open_files=256,
    processes=4_096,
    cpu_seconds=300,
    argument_count=50_000,
    argument_bytes=16 << 20,
    input_bytes=32 << 20,
)
BUILD_LIMITS = replace(
    TOOL_LIMITS,
    timeout_seconds=1_800,
    cpu_seconds=1_800,
    output_bytes=32 << 20,
    file_bytes=2 << 30,
)
SANITIZER_LIMITS = replace(
    WORKER_LIMITS,
    timeout_seconds=300,
    cpu_seconds=300,
    # ASan reserves a very large sparse shadow mapping on AArch64. RSS remains
    # tightly monitored, while this virtual-space ceiling accommodates it.
    address_space_bytes=1 << 60,
    rss_bytes=2 << 30,
)
UPSTREAM_TEST_LIMITS = replace(
    TOOL_LIMITS,
    timeout_seconds=21_600,
    cpu_seconds=21_600,
    output_bytes=64 << 20,
    address_space_bytes=8 << 30,
    rss_bytes=6 << 30,
    file_bytes=8 << 30,
)

_TOOL_NAMES = {
    "ar",
    "cc",
    "clang",
    "clang++",
    "ctags",
    "gcc",
    "g++",
    "ld",
    "nm",
    "objdump",
    "python",
    "python3",
    "readelf",
    "strip",
    "zig",
}


def _limits_for(command: Sequence[object]) -> Limits:
    name = Path(os.fspath(command[0])).name
    if name in _TOOL_NAMES or name.startswith("python"):
        return TOOL_LIMITS
    return WORKER_LIMITS


def _bounded_limit(kind: int, wanted: int) -> tuple[int, int]:
    _, hard = resource.getrlimit(kind)
    value = wanted if hard == resource.RLIM_INFINITY else min(wanted, hard)
    return value, value


def _apply_limits(limits: Limits) -> None:
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    resource.setrlimit(resource.RLIMIT_AS, _bounded_limit(resource.RLIMIT_AS, limits.address_space_bytes))
    resource.setrlimit(resource.RLIMIT_FSIZE, _bounded_limit(resource.RLIMIT_FSIZE, limits.file_bytes))
    resource.setrlimit(resource.RLIMIT_NOFILE, _bounded_limit(resource.RLIMIT_NOFILE, limits.open_files))
    resource.setrlimit(resource.RLIMIT_NPROC, _bounded_limit(resource.RLIMIT_NPROC, limits.processes))
    resource.setrlimit(resource.RLIMIT_CPU, _bounded_limit(resource.RLIMIT_CPU, limits.cpu_seconds))


def bound_current_process(limits: Limits) -> None:
    """Apply inherited non-wall-clock limits to the current tool process."""
    _apply_limits(limits)


def _command_strings(command: Sequence[object]) -> list[str]:
    if isinstance(command, (str, bytes, os.PathLike)):
        raise TypeError("bounded_subprocess requires an argv sequence; shell strings are prohibited")
    result = [os.fsdecode(os.fspath(item)) for item in command]
    if not result:
        raise ValueError("empty subprocess command")
    return result


def _input_bytes(value: str | bytes | None, *, text: bool, encoding: str, errors: str) -> bytes | None:
    if value is None:
        return None
    if text:
        if not isinstance(value, str):
            raise TypeError("text-mode subprocess input must be str")
        return value.encode(encoding, errors)
    if not isinstance(value, bytes):
        raise TypeError("binary subprocess input must be bytes")
    return value


def _process_group_rss(process_group: int) -> int:
    """Return resident bytes for all visible processes in one process group."""
    total_pages = 0
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            stat = (entry / "stat").read_text()
            fields = stat[stat.rfind(")") + 2 :].split()
            if int(fields[2]) == process_group:
                total_pages += int(fields[21])
        except (OSError, IndexError, ValueError):
            # Processes can disappear between /proc enumeration and stat reads.
            continue
    return total_pages * os.sysconf("SC_PAGE_SIZE")


def _kill_group(process: _subprocess.Popen[bytes]) -> None:
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()


def _artifact_directory() -> Path:
    ARTIFACT_ROOT.mkdir(parents=True, exist_ok=True)
    path = ARTIFACT_ROOT / f"{time.time_ns()}-{os.getpid()}"
    path.mkdir()
    return path


def _read_output(path: Path, limit: int) -> bytes:
    with path.open("rb") as stream:
        return stream.read(limit + 1)


def _write_metadata(path: Path, metadata: dict[str, object]) -> None:
    (path / "metadata.json").write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n")


def run(
    command: Sequence[object],
    *,
    cwd: str | os.PathLike[str] | None = None,
    input: str | bytes | None = None,
    stdout: int | None = None,
    stderr: int | None = None,
    capture_output: bool = False,
    check: bool = False,
    text: bool = False,
    universal_newlines: bool | None = None,
    encoding: str | None = None,
    errors: str | None = None,
    timeout: float | None = None,
    env: Mapping[str, str] | None = None,
    limits: Limits | None = None,
    **unsupported: object,
) -> CompletedProcess[str] | CompletedProcess[bytes]:
    """Run one command with mandatory output, time, memory, file, and process limits."""
    if unsupported:
        raise TypeError(f"unsupported bounded subprocess options: {', '.join(sorted(unsupported))}")
    if universal_newlines is not None:
        text = universal_newlines
    if capture_output:
        if stdout is not None or stderr is not None:
            raise ValueError("stdout/stderr may not be supplied with capture_output")
        stdout, stderr = PIPE, PIPE
    for name, destination in (("stdout", stdout), ("stderr", stderr)):
        if destination not in (None, PIPE, DEVNULL, STDOUT):
            raise TypeError(f"bounded_subprocess does not support {name} destination {destination!r}")
    if stdout == STDOUT:
        raise ValueError("STDOUT is valid only for stderr")

    argv = _command_strings(command)
    selected = limits or _limits_for(argv)
    if timeout is not None:
        selected = replace(selected, timeout_seconds=min(timeout, selected.timeout_seconds))
    argv_size = sum(len(os.fsencode(argument)) + 1 for argument in argv)
    if len(argv) > selected.argument_count or argv_size > selected.argument_bytes:
        raise ValueError(
            f"subprocess argv exceeds limit: count={len(argv)}/{selected.argument_count} "
            f"bytes={argv_size}/{selected.argument_bytes}"
        )

    codec = encoding or "utf-8"
    codec_errors = errors or "strict"
    stdin_data = _input_bytes(input, text=text, encoding=codec, errors=codec_errors)
    if stdin_data is not None and len(stdin_data) > selected.input_bytes:
        raise ValueError(f"subprocess input exceeds {selected.input_bytes} bytes")

    artifact = _artifact_directory()
    stdout_path = artifact / "stdout.bin"
    stderr_path = artifact / "stderr.bin"
    started = time.monotonic()
    timed_out = False
    rss_exceeded = False
    output_exceeded = False
    returncode: int | None = None
    process: _subprocess.Popen[bytes] | None = None
    merged = stderr == STDOUT

    with stdout_path.open("wb") as stdout_file, stderr_path.open("wb") as stderr_file:
        try:
            process = _subprocess.Popen(
                argv,
                cwd=cwd,
                stdin=_subprocess.PIPE if stdin_data is not None else _subprocess.DEVNULL,
                stdout=stdout_file,
                stderr=stdout_file if merged else stderr_file,
                env=env,
                start_new_session=True,
                preexec_fn=lambda: _apply_limits(selected),
            )
        except (OSError, _subprocess.SubprocessError) as error:
            _write_metadata(artifact, {
                "argv": argv,
                "cwd": os.fspath(cwd) if cwd is not None else os.getcwd(),
                "limits": asdict(selected),
                "spawn_error": repr(error),
            })
            setattr(error, "artifact_path", str(artifact))
            raise
        if stdin_data is not None:
            assert process.stdin is not None
            try:
                process.stdin.write(stdin_data)
            except BrokenPipeError:
                pass
            process.stdin.close()
        deadline = started + selected.timeout_seconds
        while process.poll() is None:
            if time.monotonic() >= deadline:
                timed_out = True
                _kill_group(process)
                break
            if _process_group_rss(process.pid) > selected.rss_bytes:
                rss_exceeded = True
                _kill_group(process)
                break
            try:
                output_size = stdout_path.stat().st_size
                if not merged:
                    output_size += stderr_path.stat().st_size
                if output_size > selected.output_bytes:
                    output_exceeded = True
                    _kill_group(process)
                    break
            except FileNotFoundError:
                pass
            time.sleep(0.1)
        returncode = process.returncode

    stdout_bytes = _read_output(stdout_path, selected.output_bytes)
    stderr_bytes = b"" if merged else _read_output(stderr_path, selected.output_bytes)
    output_exceeded = output_exceeded or len(stdout_bytes) + len(stderr_bytes) > selected.output_bytes
    elapsed = time.monotonic() - started
    metadata: dict[str, object] = {
        "argv": argv,
        "cwd": os.fspath(cwd) if cwd is not None else os.getcwd(),
        "elapsed_seconds": elapsed,
        "environment_override_keys": sorted(env) if env is not None else [],
        "limits": asdict(selected),
        "output_exceeded": output_exceeded,
        "returncode": returncode,
        "rss_exceeded": rss_exceeded,
        "timed_out": timed_out,
    }

    failed = timed_out or rss_exceeded or output_exceeded or returncode != 0
    if failed:
        _write_metadata(artifact, metadata)
    else:
        shutil.rmtree(artifact)

    if text:
        stdout_value: str | bytes = stdout_bytes.decode(codec, codec_errors)
        stderr_value: str | bytes = stderr_bytes.decode(codec, codec_errors)
    else:
        stdout_value = stdout_bytes
        stderr_value = stderr_bytes

    if timed_out:
        error = TimeoutExpired(argv, selected.timeout_seconds, output=stdout_value, stderr=stderr_value)
        setattr(error, "artifact_path", str(artifact))
        raise error
    if rss_exceeded:
        message = f"bounded subprocess RSS exceeded {selected.rss_bytes} bytes; artifact={artifact}"
        if text:
            stderr_value = f"{stderr_value}\n{message}" if stderr_value else message
        else:
            encoded = message.encode()
            stderr_value = stderr_value + (b"\n" if stderr_value else b"") + encoded
        error = CalledProcessError(returncode or -signal.SIGKILL, argv, output=stdout_value, stderr=stderr_value)
        setattr(error, "artifact_path", str(artifact))
        raise error
    if output_exceeded:
        message = f"bounded subprocess output exceeded {selected.output_bytes} bytes; artifact={artifact}"
        if text:
            stderr_value = f"{stderr_value}\n{message}" if stderr_value else message
        else:
            encoded = message.encode()
            stderr_value = stderr_value + (b"\n" if stderr_value else b"") + encoded
        error = CalledProcessError(returncode or -signal.SIGXFSZ, argv, output=stdout_value, stderr=stderr_value)
        setattr(error, "artifact_path", str(artifact))
        raise error

    if stdout is None:
        if text:
            sys.stdout.write(stdout_value)  # type: ignore[arg-type]
        else:
            sys.stdout.buffer.write(stdout_value)  # type: ignore[arg-type]
        returned_stdout: str | bytes | None = None
    elif stdout == DEVNULL:
        returned_stdout = None
    else:
        returned_stdout = stdout_value

    if merged:
        returned_stderr: str | bytes | None = None
    elif stderr is None:
        if text:
            sys.stderr.write(stderr_value)  # type: ignore[arg-type]
        else:
            sys.stderr.buffer.write(stderr_value)  # type: ignore[arg-type]
        returned_stderr = None
    elif stderr == DEVNULL:
        returned_stderr = None
    else:
        returned_stderr = stderr_value

    completed = CompletedProcess(argv, returncode, returned_stdout, returned_stderr)
    if check and returncode:
        error = CalledProcessError(returncode, argv, output=returned_stdout, stderr=returned_stderr)
        setattr(error, "artifact_path", str(artifact))
        raise error
    return completed


def check_output(command: Sequence[object], *, text: bool = False, **kwargs: object) -> str | bytes:
    if "stdout" in kwargs:
        raise ValueError("stdout argument not allowed for check_output")
    result = run(command, stdout=PIPE, check=True, text=text, **kwargs)
    assert result.stdout is not None
    return result.stdout
