"""Execute the actual cycle method without importing hardware/provider startup."""
import ast
import contextlib
import io
from pathlib import Path
import threading
import types
import unittest


def load_cycle():
    source_path = Path(__file__).resolve().parents[1] / 'main.py'
    tree = ast.parse(source_path.read_text(encoding='utf-8-sig'))
    bot_class = next(node for node in tree.body
                     if isinstance(node, ast.ClassDef) and node.name == 'ConfessionalBot')
    method = next(node for node in bot_class.body
                  if isinstance(node, ast.FunctionDef) and node.name == 'run_cycle')
    namespace = {
        'threading': threading,
        'time': types.SimpleNamespace(sleep=lambda _: None, time=lambda: 123),
        'random': types.SimpleNamespace(choice=lambda values: values[0]),
        'Fore': types.SimpleNamespace(**{color: '' for color in
            ('RED', 'YELLOW', 'GREEN', 'MAGENTA', 'BLUE', 'CYAN')}),
        'INTRO_PROMPTS': {'en': ['Synthetic introduction']},
        'MAX_LISTEN_ATTEMPTS': 2,
        'MIC_RETRY_S': 0,
    }
    exec(compile(ast.Module(body=[method], type_ignores=[]), str(source_path), 'exec'), namespace)
    return namespace['run_cycle']


class CycleSequenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.run_cycle = staticmethod(load_cycle())

    def run_session(self, fallback=None, answer='Synthetic answer'):
        events = []
        logs = []
        inputs = iter(['Synthetic confession', answer])

        def listen():
            result = next(inputs)
            events.append(('listen', result))
            return result

        def respond(text, phase, **context):
            events.append((phase, text, context))
            return f'Synthetic {phase} reply', phase == fallback

        def wait_speech():
            events.append(('speech_finished',))
            return True

        def publish(*args):
            events.append(('publish', *args))

        bot = types.SimpleNamespace(
            stop_event=threading.Event(), stt_ready=True, language='en',
            ensure_microphone=lambda: True, select_language=lambda: 'en',
            record_progress=lambda *args: None, log=lambda message, *args: logs.append(message),
            speak_sync=lambda *args: None, play_preloaded_or_speak=lambda *args: None,
            play_tone=lambda *args: None, confess_audio_en=None, parla_audio_en=None,
            listen_interruptible=listen, stream_response_and_play=respond,
            wait_for_speech_pipeline=wait_speech, publisher=types.SimpleNamespace(enqueue=publish),
            finish_audio_worker=lambda: events.append(('cleanup',)),
            lifecycle_lock=threading.Lock(), cycle_thread=None,
            clear_finished_threads_unlocked=lambda: None, reset_state_unlocked=lambda: None,
            has_active_cycle_unlocked=lambda: False,
        )
        with contextlib.redirect_stdout(io.StringIO()):
            self.run_cycle(bot)
        self.assertFalse(any('CRITICAL ERROR' in line for line in logs), logs)
        self.assertEqual(events[-1], ('cleanup',))
        return events

    def test_open_then_answer_then_close_then_publication(self):
        self.assertEqual(self.run_session(), [
            ('listen', 'Synthetic confession'),
            ('open', 'Synthetic confession', {}),
            ('speech_finished',),
            ('listen', 'Synthetic answer'),
            ('close', 'Synthetic answer', {'first_confession': 'Synthetic confession',
                                         'first_reply': 'Synthetic open reply'}),
            ('speech_finished',),
            ('publish', 'Synthetic confession', 'Synthetic close reply', 'en'),
            ('cleanup',),
        ])

    def test_open_fallback_excludes_publication_and_second_turn(self):
        events = self.run_session(fallback='open')
        self.assertEqual([event[0] for event in events],
                         ['listen', 'open', 'speech_finished', 'cleanup'])

    def test_close_fallback_excludes_publication(self):
        events = self.run_session(fallback='close')
        self.assertEqual([event[0] for event in events],
                         ['listen', 'open', 'speech_finished', 'listen', 'close',
                          'speech_finished', 'cleanup'])

    def test_silence_is_passed_to_close_as_none(self):
        events = self.run_session(answer='API_ERROR')
        close = next(event for event in events if event[0] == 'close')
        self.assertIsNone(close[1])
        self.assertEqual(close[2]['first_confession'], 'Synthetic confession')


if __name__ == '__main__':
    unittest.main()
