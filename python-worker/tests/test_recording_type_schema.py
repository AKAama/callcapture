from app.schemas.models import JobRequest


def test_jobrequest_defaults_recording_type_to_call_meeting():
    req = JobRequest(job_id="j1", command="transcribe", audio_path="/tmp/a.wav")
    assert req.recording_type == "call_meeting"


def test_jobrequest_accepts_known_recording_types():
    for value in ("call_meeting", "voice_memo", "lecture"):
        req = JobRequest(
            job_id="j", command="transcribe", audio_path="/tmp/a.wav",
            recording_type=value,
        )
        assert req.recording_type == value
