import json
from unittest.mock import patch

from app import cli
from app.schemas.models import Insights, JobRequest, TranscriptSegment


def _segs():
    return [
        TranscriptSegment(start=0.0, end=2.0, text="hi there", speaker="You"),
        TranscriptSegment(start=2.0, end=4.0, text="hello back", speaker="Speaker 1"),
    ]


def test_pipeline_writes_insights_and_calls_note(tmp_path, monkeypatch):
    monkeypatch.delenv("LLM_API_KEY", raising=False)
    monkeypatch.delenv("LLM_BASE_URL", raising=False)
    audio = tmp_path / "sess.wav"
    audio.write_bytes(b"")
    request = JobRequest(job_id="j", command="transcribe", audio_path=str(audio))

    ins = Insights(title="Sync", summary="We synced.", dynamics="Balanced.",
                   action_items=["ship it"])
    with patch("app.cli._transcribe_and_attribute", return_value=_segs()), \
         patch("app.cli.analyze_insights", return_value=ins):
        result = cli._run_pipeline(request)

    assert result.status == "completed"

    analysis = json.loads((tmp_path / "sess_analysis.json").read_text())
    assert analysis["insights"]["title"] == "Sync"
    assert analysis["insights"]["dynamics"] == "Balanced."

    notes = (tmp_path / "sess_notes.md").read_text()
    assert notes.startswith("---\n")
    assert "recording_type: call_meeting" in notes
    assert "# Sync" in notes
    assert "## Conversation Insights" in notes
    assert "- [ ] ship it" in notes


def test_pipeline_memo_note_shape(tmp_path, monkeypatch):
    monkeypatch.delenv("LLM_API_KEY", raising=False)
    monkeypatch.delenv("LLM_BASE_URL", raising=False)
    audio = tmp_path / "memo.wav"
    audio.write_bytes(b"")
    request = JobRequest(job_id="j", command="transcribe", audio_path=str(audio),
                         recording_type="voice_memo")

    ins = Insights(title="Idea", summary="An idea.", key_points=["point"],
                   reflections=["revisit later"])
    with patch("app.cli._transcribe_and_attribute", return_value=_segs()), \
         patch("app.cli.analyze_insights", return_value=ins):
        result = cli._run_pipeline(request)

    assert result.status == "completed"
    notes = (tmp_path / "memo_notes.md").read_text()
    assert "recording_type: voice_memo" in notes
    assert "## Reflections" in notes
    assert "- revisit later" in notes
    assert "## Conversation Insights" not in notes  # memo shape


def test_pipeline_passes_recording_type_to_analyze_insights(tmp_path, monkeypatch):
    monkeypatch.delenv("LLM_API_KEY", raising=False)
    monkeypatch.delenv("LLM_BASE_URL", raising=False)
    audio = tmp_path / "lec.wav"
    audio.write_bytes(b"")
    request = JobRequest(job_id="j", command="transcribe", audio_path=str(audio),
                         recording_type="lecture")

    with patch("app.cli._transcribe_and_attribute", return_value=_segs()), \
         patch("app.cli.analyze_insights", return_value=Insights(title="L", summary="s")) as m:
        cli._run_pipeline(request)

    assert m.call_args.kwargs["recording_type"] == "lecture"


def test_pipeline_completes_when_insights_none(tmp_path, monkeypatch):
    monkeypatch.delenv("LLM_API_KEY", raising=False)
    monkeypatch.delenv("LLM_BASE_URL", raising=False)
    audio = tmp_path / "sess.wav"
    audio.write_bytes(b"")
    request = JobRequest(job_id="j", command="transcribe", audio_path=str(audio))

    with patch("app.cli._transcribe_and_attribute", return_value=_segs()), \
         patch("app.cli.analyze_insights", return_value=None):
        result = cli._run_pipeline(request)

    assert result.status == "completed"
    analysis = json.loads((tmp_path / "sess_analysis.json").read_text())
    assert analysis["insights"] is None
    notes = (tmp_path / "sess_notes.md").read_text()
    assert notes.startswith("---\n")  # note still renders (minimal)
