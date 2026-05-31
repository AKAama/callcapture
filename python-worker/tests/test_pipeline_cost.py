from app.cli import _compute_costs
from app.schemas.models import JobRequest


def _req(**kw):
    base = dict(job_id="x", command="transcribe", audio_path="/tmp/none.wav")
    base.update(kw)
    return JobRequest(**base)


def test_local_engine_is_free(monkeypatch):
    import app.cli as cli
    monkeypatch.setattr(cli, "_count_stems", lambda path: 1)
    from app.postprocess import llm_client
    llm_client.reset_usage()
    req = _req(engine="local_whisper", llm_engine="local_experimental")
    costs = _compute_costs(req, duration_sec=600.0)
    assert costs["cost_transcription"] == 0.0
    assert costs["cost_processing"] == 0.0
    assert round(costs["audio_minutes"], 4) == 10.0


def test_remote_stems_double_transcription(monkeypatch):
    import app.cli as cli
    monkeypatch.setattr(cli, "_count_stems", lambda path: 2)
    from app.postprocess import llm_client
    llm_client.reset_usage()
    req = _req(engine="remote", remote_provider="assemblyai", llm_engine="claude")
    costs = _compute_costs(req, duration_sec=600.0)
    # 10 min × 0.0035 × 2 stems
    assert round(costs["cost_transcription"], 6) == 0.07


def test_processing_uses_actual_cost(monkeypatch):
    import app.cli as cli
    monkeypatch.setattr(cli, "_count_stems", lambda path: 1)
    from app.postprocess import llm_client
    llm_client.reset_usage()
    llm_client.record_usage(tokens=5000, cost=0.0123)
    req = _req(engine="remote", remote_provider="deepgram", llm_engine="claude")
    costs = _compute_costs(req, duration_sec=60.0)
    assert costs["cost_processing"] == 0.0123
    assert costs["llm_tokens"] == 5000


def test_processing_fallback_when_no_actual(monkeypatch):
    import app.cli as cli
    monkeypatch.setattr(cli, "_count_stems", lambda path: 1)
    from app.postprocess import llm_client
    llm_client.reset_usage()
    llm_client.record_usage(tokens=2_000_000, cost=None)
    req = _req(engine="remote", remote_provider="deepgram",
               llm_engine="claude", llm_fallback_rate_per_1m=3.0)
    costs = _compute_costs(req, duration_sec=60.0)
    assert round(costs["cost_processing"], 6) == 6.0
