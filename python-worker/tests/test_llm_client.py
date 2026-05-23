from unittest.mock import MagicMock, patch

import pytest

from app.postprocess.llm_client import LLMClient, LLMError, OPENROUTER_BASE_URL


def _fake_completion(content: str):
    msg = MagicMock()
    msg.message.content = content
    resp = MagicMock()
    resp.choices = [msg]
    return resp


def test_complete_json_returns_parsed_dict():
    client = LLMClient(api_key="k", model="google/gemini-2.5-flash")
    with patch.object(client._client.chat.completions, "create",
                      return_value=_fake_completion('{"a": 1}')):
        result = client.complete_json(system="sys", user="usr")
    assert result == {"a": 1}


def test_complete_json_strips_code_fences():
    client = LLMClient(api_key="k", model="m")
    fenced = "```json\n{\"b\": 2}\n```"
    with patch.object(client._client.chat.completions, "create",
                      return_value=_fake_completion(fenced)):
        result = client.complete_json(system="s", user="u")
    assert result == {"b": 2}


def test_defaults_to_openrouter_base_url():
    client = LLMClient(api_key="k", model="m")
    assert str(client._client.base_url).rstrip("/") == OPENROUTER_BASE_URL


def test_local_base_url_is_honored():
    client = LLMClient(api_key="ollama", model="qwen2.5:32b",
                       base_url="http://localhost:11434/v1")
    assert "11434" in str(client._client.base_url)


def test_invalid_json_raises():
    client = LLMClient(api_key="k", model="m")
    with patch.object(client._client.chat.completions, "create",
                      return_value=_fake_completion("not json")):
        with pytest.raises(LLMError):
            client.complete_json(system="s", user="u")
