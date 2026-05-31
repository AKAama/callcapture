from app.postprocess import llm_client


def test_usage_log_starts_empty_after_reset():
    llm_client.reset_usage()
    u = llm_client.get_usage()
    assert u.total_tokens == 0
    assert u.actual_cost is None


def test_record_usage_accumulates_tokens():
    llm_client.reset_usage()
    llm_client.record_usage(tokens=100, cost=None)
    llm_client.record_usage(tokens=250, cost=None)
    u = llm_client.get_usage()
    assert u.total_tokens == 350
    assert u.actual_cost is None


def test_record_usage_sums_actual_cost_when_any_present():
    llm_client.reset_usage()
    llm_client.record_usage(tokens=100, cost=0.001)
    llm_client.record_usage(tokens=100, cost=0.002)
    u = llm_client.get_usage()
    assert u.total_tokens == 200
    assert round(u.actual_cost, 6) == 0.003


def test_actual_cost_none_if_no_call_reported_cost():
    llm_client.reset_usage()
    llm_client.record_usage(tokens=100, cost=None)
    llm_client.record_usage(tokens=100, cost=0.002)
    u = llm_client.get_usage()
    # Mixed: at least one real cost present → sum the reported ones
    assert round(u.actual_cost, 6) == 0.002


def test_extract_usage_reads_tokens_and_cost_from_response_obj():
    class U:
        total_tokens = 1234
        cost = 0.0042
    class Resp:
        usage = U()
    tokens, cost = llm_client._extract_usage(Resp())
    assert tokens == 1234
    assert cost == 0.0042


def test_extract_usage_handles_missing_cost():
    class U:
        total_tokens = 50
    class Resp:
        usage = U()
    tokens, cost = llm_client._extract_usage(Resp())
    assert tokens == 50
    assert cost is None


def test_extract_usage_handles_missing_usage():
    class Resp:
        usage = None
    tokens, cost = llm_client._extract_usage(Resp())
    assert tokens == 0
    assert cost is None
