import subprocess
import sys
import threading
import unittest
import unittest.mock

from app.whisper import WhisperCppTranscriber


class ConvertToWavTests(unittest.TestCase):
    def test_stderr_larger_than_a_pipe_does_not_stall(self) -> None:
        real_popen = subprocess.Popen
        seen: dict[str, object] = {}

        def fake_popen(command, **kwargs):
            seen["command"] = command
            seen["stdout"] = kwargs.get("stdout")
            seen["stderr"] = kwargs.get("stderr")
            script = "import sys; sys.stderr.write('e' * 200000); sys.stderr.flush()"
            return real_popen([sys.executable, "-c", script], **kwargs)

        transcriber = WhisperCppTranscriber()
        result: list[str] = []
        errors: list[BaseException] = []
        finished = threading.Event()

        def run() -> None:
            try:
                with unittest.mock.patch("app.whisper.subprocess.Popen", fake_popen):
                    result.append(transcriber._convert_to_wav("source.webm", "out.wav", None, None))
            except BaseException as exc:
                errors.append(exc)
            finally:
                finished.set()

        import unittest.mock

        worker = threading.Thread(target=run)
        worker.start()
        self.assertTrue(finished.wait(5), "ffmpeg stderr drain stalled")
        worker.join(1)
        self.assertEqual(errors, [])
        self.assertEqual(result, ["ffmpeg"])
        self.assertEqual(seen["stdout"], subprocess.DEVNULL)
        self.assertEqual(seen["stderr"], subprocess.PIPE)
        command = seen["command"]
        assert isinstance(command, list)
        self.assertIn("-nostats", command)
        self.assertIn("error", command)

    def test_failed_ffmpeg_keeps_stderr_text(self) -> None:
        real_popen = subprocess.Popen

        def fake_popen(command, **kwargs):
            script = "import sys; sys.stderr.write('codec missing\\n'); sys.exit(1)"
            return real_popen([sys.executable, "-c", script], **kwargs)

        transcriber = WhisperCppTranscriber()
        with unittest.mock.patch("app.whisper.subprocess.Popen", fake_popen):
            with self.assertRaises(RuntimeError) as raised:
                transcriber._convert_to_wav("source.webm", "out.wav", None, None)
        self.assertIn("codec missing", str(raised.exception))


if __name__ == "__main__":
    unittest.main()
