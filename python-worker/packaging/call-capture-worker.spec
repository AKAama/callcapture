# -*- mode: python ; coding: utf-8 -*-
# Build:  cd python-worker && pyinstaller packaging/call-capture-worker.spec
# Output: dist/call-capture-worker/call-capture-worker
#
# The binary name MUST stay "call-capture-worker" — PythonBridge.searchPaths()
# looks for Contents/Resources/worker/call-capture-worker.
import os

from PyInstaller.utils.hooks import collect_submodules, copy_metadata

# The build runs from python-worker/ (`pyinstaller packaging/...spec`), but the
# spec's own dir is packaging/. The package root that holds `app/` is the parent
# of packaging/. Resolve it absolutely so `from app.cli import main` works
# regardless of cwd, and so PyInstaller's analysis can crawl the source tree —
# `app` is installed editable, so its custom .pth finder is NOT discoverable by
# PyInstaller's static modulegraph; it must be found via pathex + explicit
# submodule collection instead.
WORKER_ROOT = os.path.abspath(os.path.join(SPECPATH, ".."))

hiddenimports = [
    "openai",
    "httpx",
    "anthropic",
    "onnxruntime",
    "audonnx",
    "audeer",
    "audiofile",
    "numpy",
]
hiddenimports += collect_submodules("app")

datas = copy_metadata("openai") + copy_metadata("pydantic")

a = Analysis(
    [os.path.join(SPECPATH, "worker_entry.py")],
    pathex=[WORKER_ROOT],
    binaries=[],
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    runtime_hooks=[],
    excludes=["pywhispercpp"],
    noarchive=False,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="call-capture-worker",
    debug=False,
    strip=False,
    upx=False,
    console=True,
)
coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=False,
    name="call-capture-worker",
)
