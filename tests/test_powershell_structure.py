from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / "src" / "WinOfflineUpdate.psm1"


def _strip_strings_and_comments(text: str) -> str:
    out = []
    i = 0
    in_single = False
    in_double = False
    while i < len(text):
        ch = text[i]
        nxt = text[i + 1] if i + 1 < len(text) else ""
        if in_single:
            if ch == "'":
                if nxt == "'":
                    i += 2
                    continue
                in_single = False
            out.append(" ")
        elif in_double:
            if ch == '"' and (i == 0 or text[i - 1] != '`'):
                in_double = False
            out.append(" ")
        else:
            if ch == "#":
                while i < len(text) and text[i] not in "\r\n":
                    out.append(" ")
                    i += 1
                continue
            if ch == "'":
                in_single = True
                out.append(" ")
            elif ch == '"':
                in_double = True
                out.append(" ")
            else:
                out.append(ch)
        i += 1
    return "".join(out)


def test_module_has_balanced_braces():
    text = _strip_strings_and_comments(MODULE.read_text(encoding="utf-8"))
    depth = 0
    for line_no, line in enumerate(text.splitlines(), start=1):
        for ch in line:
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
            assert depth >= 0, f"unexpected closing brace near line {line_no}"
    assert depth == 0, "missing closing brace in module"


def test_fleet_functions_do_not_duplicate_computername_parameter():
    text = MODULE.read_text(encoding="utf-8")
    for function_name in ("Invoke-WouFleetScan", "Invoke-WouFleetInstall"):
        match = re.search(rf"function\s+{function_name}\s*\{{.*?param\((.*?)\)\s*\n", text, flags=re.S)
        assert match, f"could not find param block for {function_name}"
        params = re.findall(r"\$([A-Za-z_][A-Za-z0-9_]*)", match.group(1))
        lowered = [param.lower() for param in params]
        assert lowered.count("computername") == 1, f"duplicate ComputerName parameter in {function_name}"
