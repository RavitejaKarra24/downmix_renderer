"""Isolate verbatim product declarations; never supply test-side substitutes."""

import pathlib
import re
import sys


def declaration(path, prefix):
    text = path.read_text()
    starts = list(re.finditer(r"^" + re.escape(prefix) + r"(?=[ :{])", text, re.M))
    if len(starts) != 1:
        raise RuntimeError(f"Expected exactly one {prefix!r} in {path}")
    start = starts[0].start()
    # Ignore comments/ordinary strings while balancing the declaration's braces.
    # Fail closed if its syntax changes rather than silently compiling a stub.
    tokens = re.compile(r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"|[{}]', re.S)
    depth = 0
    opened = False
    for token in tokens.finditer(text, start):
        if token.group() == "{":
            opened = True
            depth += 1
        elif token.group() == "}":
            depth -= 1
            if opened and depth == 0:
                return text[start:token.end()]
    raise RuntimeError(f"Unbalanced declaration {prefix!r} in {path}")


root = pathlib.Path(sys.argv[1])
output = pathlib.Path(sys.argv[2])
app_state = root / "Sources/Downmix/AppState.swift"
processor = root / "Sources/Downmix/DSP/DownmixProcessor.swift"
output.write_text(
    "import Foundation\n\n"
    + declaration(app_state, "extension Notification.Name")
    + "\n\n"
    + declaration(app_state, "final class MeterSource")
    + "\n\n"
    + declaration(processor, "struct MeterSnapshot")
    + "\n"
)
