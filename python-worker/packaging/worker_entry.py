"""PyInstaller entry point for the packaged worker.

Delegates to the existing Click CLI so the frozen binary exposes the same
commands (`transcribe`, `postprocess`, `export`, `prepare_emotion`) and the
same stdin/stdout JSON contract as `python -m app.cli`.
"""
from app.cli import main

if __name__ == "__main__":
    main()
