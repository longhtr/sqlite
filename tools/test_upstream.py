#!/usr/bin/env python3
"""Build SQLite's Tcl testfixture and run the pinned C-oracle test partition."""

from __future__ import annotations

import os
import pathlib
import shutil

import bounded_subprocess as subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent
DEPS = ROOT / ".reference-build/deps"
BUILD = ROOT / ".reference-build/upstream-tests"


def require_command(name: str) -> str:
    path = shutil.which(name)
    if path is None:
        raise SystemExit(f"test-upstream: required command not found: {name}")
    return path


def bootstrap_fedora_tcl8() -> tuple[pathlib.Path, pathlib.Path, pathlib.Path, pathlib.Path]:
    rpm_directory = DEPS / "tcl8-rpms"
    root = DEPS / "tcl8"
    rpm_directory.mkdir(parents=True, exist_ok=True)
    root.mkdir(parents=True, exist_ok=True)
    if not list(rpm_directory.glob("tcl8-*.rpm")):
        subprocess.run(
            [require_command("dnf"), "download", f"--destdir={rpm_directory}", "tcl8", "tcl8-devel"],
            check=True,
            limits=subprocess.UPSTREAM_TEST_LIMITS,
        )
    tclsh = root / "usr/bin/tclsh8.6"
    if not tclsh.is_file():
        rpm2cpio = require_command("rpm2cpio")
        cpio = require_command("cpio")
        for package in sorted(rpm_directory.glob("*.rpm")):
            archive = subprocess.check_output(
                [rpm2cpio, package],
                limits=subprocess.UPSTREAM_TEST_LIMITS,
            )
            subprocess.run(
                [cpio, "-idm", "--quiet"],
                cwd=root,
                input=archive,
                check=True,
                limits=subprocess.UPSTREAM_TEST_LIMITS,
            )
    library_directory = root / "usr/lib64"
    tcl_library = root / "usr/share/tcl8.6"
    source_config = library_directory / "tclConfig.sh"
    config_directory = DEPS / "tcl8-config"
    config_directory.mkdir(parents=True, exist_ok=True)
    config = config_directory / "tclConfig.sh"
    text = source_config.read_text()
    include = root / "usr/include"
    replacements = {
        "TCL_BUILD_LIB_SPEC='-L/usr/lib64 -ltcl8.6'": f"TCL_BUILD_LIB_SPEC='-L{library_directory} -ltcl8.6'",
        "TCL_LIB_SPEC='-L/usr/lib64 -ltcl8.6'": f"TCL_LIB_SPEC='-L{library_directory} -ltcl8.6'",
        "TCL_INCLUDE_SPEC='-I/usr/include'": f"TCL_INCLUDE_SPEC='-I{include}'",
        "TCL_SRC_DIR='/usr/include/tcl-private'": f"TCL_SRC_DIR='{include / 'tcl-private'}'",
        "TCL_STUB_LIB_SPEC='-L/usr/lib64 -ltclstub8.6'": f"TCL_STUB_LIB_SPEC='-L{library_directory} -ltclstub8.6'",
    }
    for old, new in replacements.items():
        if old not in text:
            raise SystemExit(f"test-upstream: Tcl config template drift: {old}")
        text = text.replace(old, new)
    config.write_text(text)
    return tclsh, config, library_directory, tcl_library


def locate_tcl() -> tuple[pathlib.Path, pathlib.Path, pathlib.Path | None, pathlib.Path | None]:
    if os.environ.get("TCLSH") and os.environ.get("TCL_CONFIG_SH"):
        return (
            pathlib.Path(os.environ["TCLSH"]),
            pathlib.Path(os.environ["TCL_CONFIG_SH"]),
            pathlib.Path(os.environ["TCL_LIBRARY_DIR"]) if os.environ.get("TCL_LIBRARY_DIR") else None,
            pathlib.Path(os.environ["TCL_LIBRARY"]) if os.environ.get("TCL_LIBRARY") else None,
        )
    system_tclsh = shutil.which("tclsh8.6")
    if system_tclsh:
        candidates = sorted(
            path
            for base in (pathlib.Path("/usr/lib"), pathlib.Path("/usr/lib64"))
            for path in base.glob("**/tcl8.6/tclConfig.sh")
        )
        if not candidates:
            raise SystemExit("test-upstream: system tclConfig.sh not found")
        return pathlib.Path(system_tclsh), candidates[0], None, None
    return bootstrap_fedora_tcl8()


def main() -> None:
    jobs = os.environ.get("SQLITE_TEST_JOBS", "2")
    permutation = os.environ.get("SQLITE_TEST_PERMUTATION", "veryquick")
    tclsh, tcl_config, library_directory, tcl_library = locate_tcl()
    shutil.rmtree(BUILD, ignore_errors=True)
    BUILD.mkdir(parents=True)
    environment = dict(os.environ)
    if library_directory is not None:
        previous = environment.get("LD_LIBRARY_PATH")
        environment["LD_LIBRARY_PATH"] = f"{library_directory}{':' + previous if previous else ''}"
    if tcl_library is not None:
        environment["TCL_LIBRARY"] = str(tcl_library)

    limits = subprocess.UPSTREAM_TEST_LIMITS
    subprocess.run(
        [
            ROOT / "upstream/sqlite/configure",
            f"--with-tcl={tcl_config.parent}",
            f"--with-tclsh={tclsh}",
        ],
        cwd=BUILD,
        env=environment,
        check=True,
        limits=limits,
    )
    subprocess.run(["make", f"-j{jobs}", "testfixture"], cwd=BUILD, env=environment, check=True, limits=limits)
    shutil.rmtree(BUILD / "testdir", ignore_errors=True)
    for path in (BUILD / "testrunner.db", BUILD / "testrunner.log"):
        path.unlink(missing_ok=True)
    subprocess.run(
        [
            BUILD / "testfixture",
            ROOT / "upstream/sqlite/test/testrunner.tcl",
            "--jobs",
            jobs,
            permutation,
        ],
        cwd=BUILD,
        env=environment,
        check=True,
        limits=limits,
    )


if __name__ == "__main__":
    main()
