"""Check native rendering and compatibility of the existing compiler protocol."""
import base64
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent.parent


def main():
    with subprocess.Popen(
        [str(ROOT / "target/release/writer-helper")],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
    ) as helper:
        try:
            def compile_document(text, revision, native=False):
                params = {
                    "root": str(ROOT / "examples"),
                    "entry": "main.typ",
                    "files": {"main.typ": text},
                    "revision": revision,
                }
                if native:
                    params["native_preview"] = True
                request = {"jsonrpc": "2.0", "id": revision, "method": "compile", "protocolVersion": 1, "params": params}
                helper.stdin.write(json.dumps(request) + "\n")
                helper.stdin.flush()
                response = json.loads(helper.stdout.readline())
                assert "error" not in response, response
                return response["result"]

            text = (ROOT / "examples/Tutorial.typ").read_text()
            legacy = compile_document(text, 1)
            assert not legacy["diagnostics"], legacy
            assert "pageImages" not in legacy
            assert base64.b64decode(legacy["pdf"]).startswith(b"%PDF-")
            rendered = compile_document(text, 2, native=True)
            assert not rendered["diagnostics"], rendered
            assert len(rendered["pageImages"]) == rendered["pages"] > 0
            assert base64.b64decode(rendered["pageImages"][0]).startswith(b"\x89PNG\r\n\x1a\n")
            assert rendered["sourceMap"]
            broken = compile_document("#let x = (", 3, native=True)
            assert broken["diagnostics"]
            assert "pdf" not in broken
            print("Native page rendering, PDF export data, source map, invalid source, and legacy protocol passed.")
        finally:
            helper.terminate()
            helper.wait(timeout=10)


if __name__ == "__main__":
    main()
