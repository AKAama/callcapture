from app.postprocess import pricing


def test_transcription_cost_single_stem():
    # 10 min × $0.0035/min × 1 stem
    c = pricing.transcription_cost(10.0, "assemblyai", 1, pricing.DEFAULT_STT_RATE_PER_MIN)
    assert round(c, 6) == 0.035


def test_transcription_cost_doubles_for_two_stems():
    c = pricing.transcription_cost(10.0, "assemblyai", 2, pricing.DEFAULT_STT_RATE_PER_MIN)
    assert round(c, 6) == 0.07


def test_transcription_cost_local_is_zero():
    c = pricing.transcription_cost(60.0, "local_whisper", 2, pricing.DEFAULT_STT_RATE_PER_MIN)
    assert c == 0.0


def test_transcription_cost_unknown_provider_is_zero():
    # Unknown provider → rate 0 (never crash on a typo)
    c = pricing.transcription_cost(10.0, "mystery", 1, pricing.DEFAULT_STT_RATE_PER_MIN)
    assert c == 0.0


def test_transcription_cost_override_rate_wins():
    rates = pricing.merge_rates({"assemblyai": 0.01})
    c = pricing.transcription_cost(10.0, "assemblyai", 1, rates)
    assert round(c, 6) == 0.1


def test_merge_rates_falls_back_to_defaults_for_missing_keys():
    rates = pricing.merge_rates({"assemblyai": 0.01})
    assert rates["deepgram"] == pricing.DEFAULT_STT_RATE_PER_MIN["deepgram"]
    assert rates["assemblyai"] == 0.01


def test_merge_rates_ignores_none_and_negative():
    rates = pricing.merge_rates({"assemblyai": None, "deepgram": -5})
    assert rates["assemblyai"] == pricing.DEFAULT_STT_RATE_PER_MIN["assemblyai"]
    assert rates["deepgram"] == pricing.DEFAULT_STT_RATE_PER_MIN["deepgram"]


def test_processing_cost_uses_actual_when_present():
    c = pricing.processing_cost(0.0123, 5000, 3.0)
    assert c == 0.0123


def test_processing_cost_falls_back_to_tokens_when_actual_none():
    # 2,000,000 tokens × $3 / 1e6 = $6
    c = pricing.processing_cost(None, 2_000_000, 3.0)
    assert round(c, 6) == 6.0


def test_processing_cost_zero_tokens_no_actual_is_zero():
    assert pricing.processing_cost(None, 0, 3.0) == 0.0
