"""Offline privacy regression tests. All names, tokens and text are synthetic."""
import io
import json
from pathlib import Path
import tempfile
import types
import unittest
from unittest.mock import patch
import urllib.error

import publisher


class FakeLLM:
    def __init__(self, results):
        self.results = iter(results)
        self.calls = []
        self.chat = types.SimpleNamespace(completions=self)

    def create(self, **kwargs):
        self.calls.append(kwargs)
        result = next(self.results)
        if isinstance(result, Exception):
            raise result
        return types.SimpleNamespace(choices=[types.SimpleNamespace(
            message=types.SimpleNamespace(content=result))])


class FakeHTTP:
    def __init__(self, error=None):
        self.requests = []
        self.error = error

    def open(self, request, **kwargs):
        self.requests.append(request)
        if self.error:
            raise self.error
        return self

    status = 200

    def __enter__(self):
        return self

    def __exit__(self, *args):
        pass


class PublisherPrivacyTests(unittest.TestCase):
    raw = {'confession': 'I deceived Synthetic Alice at 99 Test Lane.',
           'reply': 'Synthetic Alice, give back the benefit.', 'lang': 'en', 'ts': 123}
    clean = ['"I deceived someone."', 'Give back the benefit.']

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / 'pending.jsonl'
        self.transport = FakeHTTP()
        self.addCleanup(patch.stopall)
        patch.object(publisher.urllib.request, 'urlopen', self.transport.open).start()
        patch.object(publisher.urllib.request, 'build_opener', return_value=self.transport).start()
        self.worker = publisher.PublishWorker('https://receiver.invalid/ingest',
            'synthetic-token', '', 'synthetic-model', http_retries=1,
            pending_path=str(self.path))
        self.worker._stop_event.wait = lambda timeout: False
        self.llm = FakeLLM(self.clean)
        self.worker._groq_client = self.llm

    def pending_text(self):
        return self.path.read_text(encoding='utf-8') if self.path.exists() else ''

    def prepared(self):
        return dict(self.raw, confession=self.clean[0], processed=self.clean[0],
                    reply=self.clean[1], _prepared_schema=1)

    def test_receiver_gets_only_sanitized_confession_and_reply(self):
        self.worker._process(dict(self.raw))
        payload = json.loads(self.transport.requests[0].data)
        self.assertEqual(payload, dict(self.raw, confession=self.clean[0],
            processed=self.clean[0], reply=self.clean[1]))
        self.assertEqual(len(self.llm.calls), 2)
        prompt = self.llm.calls[1]['messages'][0]['content'].lower()
        self.assertIn('tone', prompt)
        self.assertIn('identifying', prompt)
        self.assertNotEqual(prompt, self.llm.calls[0]['messages'][0]['content'].lower())

    def test_cached_processed_never_bypasses_sanitizing_raw_fields(self):
        self.worker._process(dict(self.raw, processed='Cached synthetic text'))
        payload = json.loads(self.transport.requests[0].data)
        self.assertEqual(payload['confession'], self.clean[0])
        self.assertEqual(payload['reply'], self.clean[1])

    def test_summary_failure_drops_raw_text_without_persistence(self):
        self.worker._groq_client = FakeLLM([''])
        with self.assertLogs('algorithmcreed', 'WARNING'):
            self.worker._process(dict(self.raw))
        self.assertEqual(self.transport.requests, [])
        self.assertEqual(self.pending_text(), '')

    def test_reply_failure_drops_entire_item_without_persistence(self):
        self.worker._groq_client = FakeLLM([self.clean[0], RuntimeError(self.raw['reply'])])
        with self.assertLogs('algorithmcreed', 'WARNING') as logs:
            self.worker._process(dict(self.raw))
        self.assertEqual(self.transport.requests, [])
        self.assertEqual(self.pending_text(), '')
        self.assertNotIn('Synthetic Alice', '\n'.join(logs.output))

    def test_http_failure_persists_only_sanitized_schema(self):
        self.transport.error = urllib.error.HTTPError('https://receiver.invalid', 401,
            'synthetic-token', {}, io.BytesIO(b'Synthetic Alice synthetic-token'))
        with self.assertLogs('algorithmcreed', 'WARNING') as logs:
            self.worker._process(dict(self.raw))
        self.assertEqual(json.loads(self.pending_text()), self.prepared())
        self.assertNotIn('Synthetic Alice', '\n'.join(logs.output))
        self.assertNotIn('synthetic-token', '\n'.join(logs.output))

    def test_provider_exception_is_not_logged(self):
        self.worker._groq_client = FakeLLM([RuntimeError('synthetic-token Synthetic Alice')])
        with self.assertLogs('algorithmcreed', 'WARNING') as logs:
            self.worker._process(dict(self.raw))
        self.assertNotIn('synthetic-token', '\n'.join(logs.output))
        self.assertNotIn('Synthetic Alice', '\n'.join(logs.output))

    def test_restart_reprocesses_legacy_pending_even_with_processed(self):
        self.path.write_text(json.dumps(dict(self.raw, processed='Cached'))+'\n', encoding='utf-8')
        self.worker._drain_pending_file()
        payload = json.loads(self.transport.requests[0].data)
        self.assertEqual(payload['confession'], self.clean[0])
        self.assertEqual(payload['reply'], self.clean[1])
        self.assertEqual(self.pending_text(), '')

    def test_restart_sanitization_failure_does_not_retain_raw_pending(self):
        self.path.write_text(json.dumps(self.raw)+'\n', encoding='utf-8')
        self.worker._groq_client = FakeLLM([''])
        with self.assertLogs('algorithmcreed', 'WARNING'):
            self.worker._drain_pending_file()
        self.assertEqual(self.pending_text(), '')
        self.assertEqual(self.transport.requests, [])

    def test_unexpected_worker_failure_does_not_persist_or_log_raw_item(self):
        self.worker._queue.put(dict(self.raw))
        self.worker._queue.put(None)
        with patch.object(self.worker, '_process', side_effect=RuntimeError('Synthetic Alice')):
            with self.assertLogs('algorithmcreed', 'WARNING') as logs:
                self.worker._run()
        self.assertEqual(self.pending_text(), '')
        self.assertNotIn('Synthetic Alice', '\n'.join(logs.output))

    def test_non_https_endpoint_is_rejected_before_credentials_are_sent(self):
        for url in ('http://receiver.invalid/ingest', '', 'file:///tmp/data',
                    'https://', 'https://user:pass@receiver.invalid'):
            with self.subTest(url=url), self.assertRaises(ValueError):
                publisher.PublishWorker(url, 'synthetic-token', '', 'synthetic-model')

    def test_empty_redacted_reply_drops_item(self):
        self.worker._groq_client = FakeLLM([self.clean[0], '   '])
        with self.assertLogs('algorithmcreed', 'WARNING'):
            self.worker._process(dict(self.raw))
        self.assertEqual(self.transport.requests, [])
        self.assertEqual(self.pending_text(), '')

    def test_network_error_text_is_not_logged_and_sanitized_item_is_retained(self):
        self.transport.error = RuntimeError('synthetic-token Synthetic Alice')
        with self.assertLogs('algorithmcreed', 'WARNING') as logs:
            self.worker._process(dict(self.raw))
        self.assertNotIn('synthetic-token', '\n'.join(logs.output))
        self.assertNotIn('Synthetic Alice', '\n'.join(logs.output))
        self.assertEqual(json.loads(self.pending_text())['reply'], self.clean[1])

    def test_retry_http_failure_retains_only_newly_sanitized_item(self):
        self.path.write_text(json.dumps(dict(self.raw, processed='Cached'))+'\n', encoding='utf-8')
        self.transport.error = RuntimeError('synthetic error')
        with self.assertLogs('algorithmcreed', 'WARNING'):
            self.worker._drain_pending_file()
        self.assertEqual(json.loads(self.pending_text()), self.prepared())

    def test_stopped_replay_retains_prepared_entries_without_provider_calls(self):
        self.path.write_text(json.dumps(self.prepared())+'\n', encoding='utf-8')
        self.worker._stop_event.set()
        self.worker._drain_pending_file()
        self.assertEqual(json.loads(self.pending_text()), self.prepared())
        self.assertEqual(self.llm.calls, [])
        self.assertEqual(self.transport.requests, [])

    def test_prepared_retry_succeeds_during_provider_outage_without_rewriting_text(self):
        self.path.write_text(json.dumps(self.prepared())+'\n', encoding='utf-8')
        self.worker._groq_client = None
        self.worker._drain_pending_file()
        self.assertEqual(len(self.transport.requests), 1)
        payload = json.loads(self.transport.requests[0].data)
        self.assertEqual(payload['confession'], self.clean[0])
        self.assertEqual(payload['reply'], self.clean[1])
        self.assertNotIn('_prepared_schema', payload)
        self.assertEqual(self.pending_text(), '')

    def test_graceful_stop_after_first_ack_keeps_remaining_prepared_item(self):
        second = dict(self.prepared(), ts=456)
        self.path.write_text(json.dumps(self.prepared())+'\n'+json.dumps(second)+'\n', encoding='utf-8')
        def stop_after_post(request, **kwargs):
            self.worker._stop_event.set()
            return self.transport.open(request, **kwargs)
        with patch.object(self.worker, '_opener', types.SimpleNamespace(open=stop_after_post)):
            self.worker._drain_pending_file()
        self.assertEqual(json.loads(self.pending_text()), second)
        self.assertEqual(len(self.transport.requests), 1)
        self.assertEqual(self.llm.calls, [])

    def test_prepared_retry_http_failure_preserves_identical_item_without_llm(self):
        self.path.write_text(json.dumps(self.prepared())+'\n', encoding='utf-8')
        self.transport.error = RuntimeError('synthetic failure')
        with self.assertLogs('algorithmcreed', 'WARNING'):
            self.worker._drain_pending_file()
        self.assertEqual(json.loads(self.pending_text()), self.prepared())
        self.assertEqual(self.llm.calls, [])

    def test_replay_spool_contains_only_prepared_items_before_first_http_request(self):
        self.path.write_text(json.dumps(self.raw)+'\n', encoding='utf-8')
        at_post = []
        def inspect_spool(request, **kwargs):
            at_post.append(json.loads(self.pending_text()))
            return self.transport.open(request, **kwargs)
        with patch.object(self.worker, '_opener', types.SimpleNamespace(open=inspect_spool)):
            self.worker._drain_pending_file()
        self.assertEqual(at_post, [self.prepared()])

    def test_stopped_mixed_spool_keeps_prepared_and_drops_legacy_raw(self):
        self.path.write_text(json.dumps(self.raw)+'\n'+json.dumps(self.prepared())+'\n', encoding='utf-8')
        self.worker._stop_event.set()
        self.worker._drain_pending_file()
        self.assertEqual(json.loads(self.pending_text()), self.prepared())
        self.assertEqual(self.llm.calls, [])

    def test_invalid_prepared_schema_is_never_sent_or_persisted(self):
        for changes in ({'processed': 'mismatch'}, {'reply': None}, {'ts': 'raw text'},
                        {'lang': 'bad'}, {'_prepared_schema': 999}, {'extra': 'raw text'}):
            with self.subTest(changes=changes):
                self.path.write_text(json.dumps(dict(self.prepared(), **changes))+'\n', encoding='utf-8')
                self.worker._drain_pending_file()
                self.assertEqual(self.pending_text(), '')
                self.assertEqual(self.transport.requests, [])

    def test_atomic_spool_failure_keeps_prepared_items_and_does_not_transmit(self):
        self.path.write_text(json.dumps(self.prepared())+'\n', encoding='utf-8')
        with patch.object(publisher.os, 'replace', side_effect=OSError('synthetic-token')):
            with self.assertLogs('algorithmcreed', 'WARNING') as logs:
                self.worker._drain_pending_file()
        self.assertEqual(json.loads(self.pending_text()), self.prepared())
        self.assertEqual(self.transport.requests, [])
        self.assertNotIn('synthetic-token', '\n'.join(logs.output))

    def test_acknowledgement_rewrite_failure_retains_existing_spool(self):
        self.path.write_text(json.dumps(self.prepared())+'\n', encoding='utf-8')
        replace = publisher.os.replace
        calls = []
        def fail_after_first_replace(source, destination):
            calls.append(destination)
            if len(calls) == 2:
                raise OSError('synthetic-token')
            return replace(source, destination)
        with patch.object(publisher.os, 'replace', side_effect=fail_after_first_replace):
            with self.assertLogs('algorithmcreed', 'WARNING') as logs:
                self.worker._drain_pending_file()
        self.assertEqual(len(self.transport.requests), 1)
        self.assertEqual(json.loads(self.pending_text()), self.prepared())
        self.assertNotIn('synthetic-token', '\n'.join(logs.output))

    def test_stop_during_legacy_redaction_preserves_just_prepared_item(self):
        self.path.write_text(json.dumps(self.raw)+'\n', encoding='utf-8')
        create = self.llm.create
        def stop_after_redaction(**kwargs):
            response = create(**kwargs)
            if len(self.llm.calls) == 2:
                self.worker._stop_event.set()
            return response
        self.llm.create = stop_after_redaction
        self.worker._drain_pending_file()
        self.assertEqual(json.loads(self.pending_text()), self.prepared())
        self.assertEqual(self.transport.requests, [])

    def test_live_item_is_prepared_and_durable_before_first_http_request(self):
        at_post = []
        def inspect_spool(request, **kwargs):
            at_post.append(json.loads(self.pending_text()))
            return self.transport.open(request, **kwargs)
        with patch.object(self.worker, '_opener', types.SimpleNamespace(open=inspect_spool)):
            self.worker._process(dict(self.raw))
        self.assertEqual(at_post, [self.prepared()])
        self.assertEqual(self.pending_text(), '')

    def test_redirect_handler_never_forwards_token(self):
        handler = publisher._NoRedirects()
        request = publisher.urllib.request.Request('https://receiver.invalid',
            headers={'X-Ingest-Token': 'synthetic-token'})
        for destination in ('http://receiver.invalid', 'https://other.invalid'):
            with self.subTest(destination=destination):
                self.assertIsNone(handler.redirect_request(request, None, 302, '', {}, destination))

    def test_missing_provider_drops_item(self):
        self.worker._groq_client = None
        with self.assertLogs('algorithmcreed', 'WARNING'):
            self.worker._process(dict(self.raw))
        self.assertEqual(self.transport.requests, [])
        self.assertEqual(self.pending_text(), '')


if __name__ == '__main__':
    unittest.main()
