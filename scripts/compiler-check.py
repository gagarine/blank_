#!/usr/bin/env python3
"""Compatibility entry for the compiler integration suite."""
import pathlib, runpy
runpy.run_path(str(pathlib.Path(__file__).resolve().parents[1]/"Tests/Integration/CompilerProtocolChecks.py"),run_name="__main__")
