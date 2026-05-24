import json
import os
from unittest.mock import patch

from app.schemas.models import JobRequest, TranscriptSegment


def _seg(start, end, text):
    return TranscriptSegment(start=start, end=end, text=text)


def test_stem_pipeline_attributes_and_writes_analysis(tmp_path):
    from app import cli

    audio = tmp_path / "sess.wav"
    audio.write_bytes(b"")
    (tmp_path / "sess_mic.wav").write_bytes(b"")
    (tmp_path / "sess_system.wav").write_bytes(b"")

    request = JobRequest(job_id="j", command="transcribe", audio_path=str(audio))

    def fake_transcribe_path(path, req, progress_callback=None):
        if path.endswith("_mic.wav"):
            return [_seg(0.0, 2.0, "hello from me")]
        return [_seg(2.0, 6.0, "reply from them")]

    with patch("app.cli.transcribe_path", side_effect=fake_transcribe_path):
        segments = cli._transcribe_and_attribute(request)
        analysis_path = cli._write_analysis(request, segments)

    assert [s.speaker for s in segments] == ["You", "Speaker 1"]
    assert os.path.exists(analysis_path)
    data = json.loads(open(analysis_path).read())
    assert data["num_speakers"] == 2
    labels = {s["label"] for s in data["speakers"]}
    assert labels == {"You", "Speaker 1"}


def test_no_stems_falls_back_to_single_file(tmp_path):
    from app import cli

    audio = tmp_path / "sess.wav"
    audio.write_bytes(b"")
    request = JobRequest(job_id="j", command="transcribe", audio_path=str(audio))

    with patch("app.cli.transcribe", return_value=[_seg(0.0, 3.0, "only system")]):
        segments = cli._transcribe_and_attribute(request)

    assert segments[0].speaker == "Speaker 1"


def test_no_stems_voice_memo_is_self(tmp_path):
    from app import cli

    audio = tmp_path / "memo.wav"
    audio.write_bytes(b"")
    request = JobRequest(
        job_id="j",
        command="transcribe",
        audio_path=str(audio),
        recording_type="voice_memo",
    )

    with patch("app.cli.transcribe", return_value=[_seg(0.0, 3.0, "just me talking")]):
        segments = cli._transcribe_and_attribute(request)

    assert segments[0].speaker == "You"
