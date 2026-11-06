"""Export the editable guide as a dependency-free, printable HTML text edition.

Run from any directory: python tools/export_android_send_guide.py
Markdown is preserved as readable text; the source remains authoritative.
"""

from html import escape
from pathlib import Path

guide = Path(__file__).resolve().parents[1] / "docs/tutorial/android-send.md"
output = guide.with_suffix(".html")
output.write_text(
    "<!doctype html><html lang='en'><meta charset='utf-8'>"
    "<meta name='viewport' content='width=device-width,initial-scale=1'>"
    "<title>Send Android text to your PC — Hopboard</title>"
    "<style>body{margin:2rem auto;padding:0 1.5rem;max-width:54rem;color:#202124;"
    "background:white;font:17px/1.65 system-ui,sans-serif}pre{white-space:pre-wrap;"
    "overflow-wrap:anywhere;font:inherit}a{color:#174b87}@media print{body{margin:0;"
    "font-size:11pt}pre{white-space:pre-wrap}}</style><main>"
    "<p>Plain-text edition · <a href='android-send.md'>Editable Markdown source</a></p>"
    f"<pre>{escape(guide.read_text(encoding='utf-8'))}</pre></main></html>",
    encoding="utf-8",
)
print(output)
