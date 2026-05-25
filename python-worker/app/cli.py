"""Click CLI entry point for the callcapture worker."""

from __future__ import annotations

import json
import os
import signal
import sys
from typing import Any

import click

from app.analyze.attribution import attribute_segments
from app.analyze.diarization import load_diarization_turns
from app.analyze.metrics import compute_speaker_stats
from app.export.writer import write_markdown, write_raw_transcript
from app.analyze.sentiment import analyze_sentiment
from app.postprocess.formatter import render_markdown, render_sentiment_section
from app.postprocess.markdown import generate_markdown
from app.schemas.models import (
    ConversationAnalysis,
    JobRequest,
    JobResult,
    Sentiment,
    TranscriptSegment,
)
from app.transcribe.engine import transcribe, transcribe_path
from app.utils.progress import report_progress, report_result

_shutdown_requested = False


def _handle_sigterm(_signum: int, _frame: Any) -> None:
    global _shutdown_requested
    _shutdown_requested = True
    sys.stderr.write('{"signal": "SIGTERM received, shutting down"}\n')
    sys.stderr.flush()


signal.signal(signal.SIGTERM, _handle_sigterm)


def _check_ping(raw: str) -> bool:
    """Check for ping/pong heartbeat, respond if detected."""
    try:
        data = json.loads(raw)
        if data.get("action") == "ping":
            sys.stderr.write(json.dumps({"pong": True}) + "\n")
            sys.stderr.flush()
            return True
    except (json.JSONDecodeError, AttributeError):
        pass
    return False


def _transcribe_and_attribute(request: JobRequest) -> list[TranscriptSegment]:
    """Transcribe stems when present (mic = You, system = remote, attributed by
    the diarization sidecar), else transcribe the single mixed file as remote."""
    base = os.path.splitext(request.audio_path)[0]
    mic_path = f"{base}_mic.wav"
    system_path = f"{base}_system.wav"

    if os.path.exists(mic_path) and os.path.exists(system_path):
        mic_segments = transcribe_path(mic_path, request)
        system_segments = transcribe_path(system_path, request)
        turns = load_diarization_turns(system_path)
        return attribute_segments(mic_segments, system_segments, turns, self_label="You")

    # No stems: transcribe the mixed/single file.
    segments = transcribe(request)
    if request.recording_type == "voice_memo":
        # A solo memo is the user speaking.
        return attribute_segments(segments, [], None, self_label="You")
    turns = load_diarization_turns(request.audio_path)
    return attribute_segments([], segments, turns, self_label="You")


def _write_analysis(
    request: JobRequest,
    segments: list[TranscriptSegment],
    sentiment: Sentiment | None = None,
) -> str:
    """Build and write `<base>_analysis.json`; return its path."""
    speakers = compute_speaker_stats(segments, self_label="You")
    analysis = ConversationAnalysis(
        recording_type=request.recording_type,
        num_speakers=len(speakers),
        speakers=speakers,
        sentiment=sentiment,
    )
    base = os.path.splitext(request.audio_path)[0]
    analysis_path = f"{base}_analysis.json"
    tmp = analysis_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(analysis.model_dump_json(indent=2))
    os.replace(tmp, analysis_path)
    return analysis_path


def _run_pipeline(request: JobRequest) -> JobResult:
    """Execute the full transcribe -> postprocess -> export pipeline."""
    warnings: list[str] = []

    report_progress(request.job_id, 0.0, "starting")

    segments = _transcribe_and_attribute(request)
    if not segments:
        return JobResult(
            job_id=request.job_id,
            status="failed",
            error_message="No transcript segments produced",
            warnings=warnings,
        )

    sentiment = analyze_sentiment(segments)
    analysis_path = _write_analysis(request, segments, sentiment)

    report_progress(request.job_id, 0.5, "postprocessing")

    note = generate_markdown(segments, profile=request.markdown_profile)

    rendered = render_markdown(note, profile=request.markdown_profile)
    section = render_sentiment_section(sentiment)
    if section:
        rendered = f"{rendered}\n{section}"

    report_progress(request.job_id, 0.8, "exporting")

    base_dir = os.path.dirname(request.audio_path)
    base_name = os.path.splitext(os.path.basename(request.audio_path))[0]
    raw_path = os.path.join(base_dir, f"{base_name}_transcript.json")
    md_path = os.path.join(base_dir, f"{base_name}_notes.md")

    write_raw_transcript(segments, raw_path)
    write_markdown(rendered, md_path)

    duration_sec: float | None = None
    if segments:
        duration_sec = segments[-1].end

    report_progress(request.job_id, 1.0, "done")

    return JobResult(
        job_id=request.job_id,
        status="completed",
        raw_transcript_path=raw_path,
        markdown_path=md_path,
        analysis_path=analysis_path,
        duration_sec=duration_sec,
        warnings=warnings,
    )


@click.group()
def cli() -> None:
    """CallCapture Python worker CLI."""


def main() -> None:
    """Entry point that disables Click's standalone mode to preserve stdout."""
    cli(standalone_mode=False)


@cli.command()
@click.pass_context
def transcribe_cmd(ctx: click.Context) -> None:
    """Read a JobRequest from stdin and run the full pipeline."""
    raw = click.get_text_stream("stdin").read().strip()
    if not raw:
        sys.stderr.write('{"error": "empty stdin"}\n')
        sys.stderr.flush()
        ctx.exit(1)
        return

    if _check_ping(raw):
        return

    try:
        request = JobRequest.model_validate_json(raw)
    except Exception as exc:
        result = JobResult(
            job_id="unknown",
            status="error",
            error_message=f"Invalid JobRequest: {exc}",
        )
        report_result(result)
        ctx.exit(1)
        return

    try:
        result = _run_pipeline(request)
    except Exception as exc:
        result = JobResult(
            job_id=request.job_id,
            status="error",
            error_message=str(exc),
        )

    report_result(result)


@cli.command()
def postprocess() -> None:
    """Run postprocessing on an existing transcript."""
    raw = click.get_text_stream("stdin").read().strip()
    if not raw or _check_ping(raw):
        return

    try:
        request = JobRequest.model_validate_json(raw)
    except Exception as exc:
        result = JobResult(job_id="unknown", status="error", error_message=str(exc))
        report_result(result)
        return

    try:
        transcript_path = os.path.splitext(request.audio_path)[0] + "_transcript.json"
        with open(transcript_path, encoding="utf-8") as f:
            seg_data = json.load(f)
        segments = [TranscriptSegment.model_validate(s) for s in seg_data]

        note = generate_markdown(segments, request.markdown_profile)
        rendered = render_markdown(note, request.markdown_profile)
        md_path = os.path.splitext(request.audio_path)[0] + "_notes.md"
        write_markdown(rendered, md_path)

        result = JobResult(
            job_id=request.job_id,
            status="completed",
            markdown_path=md_path,
        )
    except Exception as exc:
        result = JobResult(job_id=request.job_id, status="error", error_message=str(exc))

    report_result(result)


@cli.command()
def export() -> None:
    """Export transcript and notes to files."""
    raw = click.get_text_stream("stdin").read().strip()
    if not raw or _check_ping(raw):
        return

    sys.stderr.write('{"info": "export command is handled as part of transcribe pipeline"}\n')
    sys.stderr.flush()


# Register the transcribe command with the expected CLI name
cli.add_command(transcribe_cmd, name="transcribe")

if __name__ == "__main__":
    main()
