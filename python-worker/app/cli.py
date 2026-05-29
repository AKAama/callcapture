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
from app.analyze.emotion import SpeakerEmotion, compute_arc, compute_speaker_emotion, is_emotion_model_ready, prepare_emotion_model
from app.analyze.insights import analyze_insights
from app.analyze.metrics import compute_speaker_stats
from app.analyze.sentiment import analyze_sentiment
from app.export.writer import write_markdown, write_raw_transcript
from app.postprocess.formatter import render_markdown, render_note
from app.postprocess.markdown import generate_markdown
from app.schemas.models import (
    ConversationAnalysis,
    Insights,
    JobRequest,
    JobResult,
    Sentiment,
    SpeakerStats,
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


def _build_speakers(
    segments: list[TranscriptSegment],
    emotion: dict[str, SpeakerEmotion] | None = None,
) -> list[SpeakerStats]:
    """Per-speaker talk metrics, enriched with acoustic emotion when available."""
    speakers = compute_speaker_stats(segments, self_label="You")
    if emotion:
        speakers = [
            s.model_copy(update={
                "valence": emotion[s.label].valence,
                "arousal": emotion[s.label].arousal,
                "dominant_emotion": emotion[s.label].dominant_emotion,
            }) if s.label in emotion else s
            for s in speakers
        ]
    return speakers


def _write_analysis(
    request: JobRequest,
    segments: list[TranscriptSegment],
    sentiment: Sentiment | None = None,
    emotion: dict[str, SpeakerEmotion] | None = None,
    insights: Insights | None = None,
    speakers: list[SpeakerStats] | None = None,
) -> str:
    """Build and write `<base>_analysis.json`; return its path.

    `speakers` may be passed in to avoid recomputing talk metrics when the caller
    already built them (e.g. for note rendering); otherwise they are derived here.
    """
    if speakers is None:
        speakers = _build_speakers(segments, emotion)
    analysis = ConversationAnalysis(
        recording_type=request.recording_type,
        num_speakers=len(speakers),
        speakers=speakers,
        sentiment=sentiment,
        insights=insights,
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

    emotion = {}
    arc = []
    if is_emotion_model_ready():
        try:
            emotion = compute_speaker_emotion(segments, request.audio_path)
            arc = compute_arc(request.audio_path)
        except Exception as exc:  # noqa: BLE001 - emotion is best-effort
            sys.stderr.write(json.dumps({"warning": f"emotion failed: {exc}"}) + "\n")
            sys.stderr.flush()
            emotion, arc = {}, []

    emotion_summary = {
        label: {"valence": e.valence, "arousal": e.arousal, "dominant_emotion": e.dominant_emotion}
        for label, e in emotion.items()
    }
    sentiment = analyze_sentiment(
        segments,
        emotion=emotion_summary or None,
        notes_language=request.notes_language,
    )
    if sentiment is not None and arc:
        sentiment = sentiment.model_copy(update={"arc": arc})

    insights = analyze_insights(
        segments,
        recording_type=request.recording_type,
        sentiment=sentiment,
        emotion=emotion_summary or None,
        notes_language=request.notes_language,
    )
    speakers = _build_speakers(segments, emotion)
    analysis_path = _write_analysis(
        request, segments, sentiment, emotion, insights, speakers=speakers
    )

    report_progress(request.job_id, 0.5, "postprocessing")

    rendered = render_note(request.recording_type, insights, sentiment, speakers, segments)

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
@click.version_option(version="0.1.0", prog_name="call-capture-worker")
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

        note = generate_markdown(
            segments,
            request.markdown_profile,
            notes_language=request.notes_language,
        )
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


@cli.command(name="prepare_emotion")
def prepare_emotion() -> None:
    """Download the acoustic-emotion model (triggered from Settings)."""
    raw = click.get_text_stream("stdin").read().strip()
    if _check_ping(raw):
        return
    job_id = "prepare_emotion"
    try:
        data = json.loads(raw) if raw else {}
        job_id = data.get("job_id", job_id)
    except json.JSONDecodeError:
        pass

    report_progress(job_id, 0.1, "downloading emotion model")
    try:
        prepare_emotion_model()
    except Exception as exc:  # noqa: BLE001 - surface as an error result
        report_result(JobResult(job_id=job_id, status="error", error_message=str(exc)))
        return
    report_progress(job_id, 1.0, "done")
    report_result(JobResult(job_id=job_id, status="completed"))


# Register the transcribe command with the expected CLI name
cli.add_command(transcribe_cmd, name="transcribe")

if __name__ == "__main__":
    main()
