"""Atomic file writers for transcript and markdown output."""

from __future__ import annotations

import json
import os
import tempfile

from app.schemas.models import TranscriptSegment


def _atomic_write(content: str, output_path: str) -> None:
    """Write content to a file atomically via temp file + rename.

    Args:
        content: String content to write.
        output_path: Destination file path.
    """
    dir_name = os.path.dirname(output_path) or "."
    os.makedirs(dir_name, exist_ok=True)

    fd, tmp_path = tempfile.mkstemp(dir=dir_name, suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(content)
        os.replace(tmp_path, output_path)
    except BaseException:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def write_raw_transcript(
    segments: list[TranscriptSegment],
    output_path: str,
) -> None:
    """Write transcript segments as JSON.

    Args:
        segments: List of transcript segments.
        output_path: Path to write the JSON file.
    """
    data = [seg.model_dump() for seg in segments]
    _atomic_write(json.dumps(data, indent=2, ensure_ascii=False), output_path)


def write_markdown(markdown_str: str, output_path: str) -> None:
    """Write rendered markdown to a .md file.

    Args:
        markdown_str: Rendered markdown content.
        output_path: Path to write the markdown file.
    """
    _atomic_write(markdown_str, output_path)
