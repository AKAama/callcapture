import json
from unittest.mock import patch

from app import cli
from app.schemas.models import (
    JobRequest,
    Sentiment,
    SpeakerSentiment,
    TranscriptSegment,
)


def _segs():
    return [
        TranscriptSegment(start=0.0, end=2.0, text="hi there", speaker="You"),
        TranscriptSegment(start=2.0, end=4.0, text="hello back", speaker="Speaker 1"),
    ]


def test_pipeline_writes_sentiment_to_analysis_and_note(tmp_path, monkeypatch):
    # Ensure generate_markdown uses its offline rule-based fallback (no network),
    # regardless of the runner's environment.
    monkeypatch.delenv("LLM_API_KEY", raising=False)
    monkeypatch.delenv("LLM_BASE_URL", raising=False)

    audio = tmp_path / "sess.wav"
    audio.write_bytes(b"")
    request = JobRequest(job_id="j", command="transcribe", audio_path=str(audio))

    sent = Sentiment(
        overall="positive",
        overall_score=0.5,
        by_speaker={
            "You": SpeakerSentiment(label="positive", score=0.6),
            "Speaker 1": SpeakerSentiment(label="neutral", score=0.0),
        },
    )

    # Mock transcription + sentiment so no audio decode or network is needed.
    # generate_markdown runs with no LLM key -> its own rule-based fallback.
    with patch("app.cli._transcribe_and_attribute", return_value=_segs()), \
         patch("app.cli.analyze_sentiment", return_value=sent):
        result = cli._run_pipeline(request)

    assert result.status == "completed"

    analysis = json.loads((tmp_path / "sess_analysis.json").read_text())
    assert analysis["sentiment"]["overall"] == "positive"
    assert analysis["sentiment"]["by_speaker"]["You"]["label"] == "positive"

    notes = (tmp_path / "sess_notes.md").read_text()
    assert "## Sentiment" in notes
    assert "**Overall:** positive (+0.50)" in notes
