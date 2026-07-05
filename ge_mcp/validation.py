"""Lua source scanning for the run_lua validator.

strip_lua blanks comments and string literals with a single left-to-right scan.
Regex passes (comments before strings) mis-handled interleaving: a string
containing '--' ate the rest of its line and exposed later string contents to
the validator ("WORD (" inside a literal was flagged as an unknown call). The
scanner handles long brackets [=[ ]=] and escaped quotes, and stripped regions
keep their newlines so line-based definition regexes see the original layout.
"""

import re

LUA_KEYWORDS = {
    "and", "break", "do", "else", "elseif", "end", "false", "for", "function",
    "goto", "if", "in", "local", "nil", "not", "or", "repeat", "return", "then",
    "true", "until", "while",
}
LUA_BUILTINS = {
    "print", "pcall", "xpcall", "error", "assert", "type", "tostring", "tonumber",
    "ipairs", "pairs", "next", "select", "rawget", "rawset", "rawequal", "rawlen",
    "setmetatable", "getmetatable", "unpack", "require", "collectgarbage",
    "loadstring", "load", "dofile", "loadfile", "gcinfo", "newproxy",
    "getfenv", "setfenv",
}
EDITOR_GLOBALS = {
    "source", "printError", "printWarning", "printDevError", "printDevWarning",
    "printCallstack", "print_r",
}

_LONG_OPEN = re.compile(r'\[(=*)\[')


def strip_lua(code: str) -> str:
    """Blank out comments and string literals, preserving layout."""
    out = []
    i, n = 0, len(code)
    while i < n:
        ch = code[i]
        if ch == '-' and code.startswith('--', i):
            m = _LONG_OPEN.match(code, i + 2)
            if m:                                   # --[[ long comment ]] (any = level)
                close = ']' + m.group(1) + ']'
                k = code.find(close, m.end())
                end = (k + len(close)) if k != -1 else n
            else:                                   # -- line comment
                k = code.find('\n', i + 2)
                end = k if k != -1 else n           # keep the newline itself
            out.append(' ' + '\n' * code.count('\n', i, end))
            i = end
        elif ch == '[' and _LONG_OPEN.match(code, i):
            m = _LONG_OPEN.match(code, i)           # [[ long string ]]
            close = ']' + m.group(1) + ']'
            k = code.find(close, m.end())
            end = (k + len(close)) if k != -1 else n
            out.append(' ' + '\n' * code.count('\n', i, end))
            i = end
        elif ch in ('"', "'"):
            j = i + 1
            while j < n and code[j] != ch:
                j += 2 if code[j] == '\\' else 1
            i = min(j + 1, n)
            out.append(' ')
        else:
            out.append(ch)
            i += 1
    return ''.join(out)


def defined_names(code: str) -> set:
    """Names the (stripped) snippet defines itself: locals, params, loop vars."""
    names = set()
    names |= set(re.findall(r'\blocal\s+function\s+([A-Za-z_]\w*)', code))
    names |= set(re.findall(r'\bfunction\s+([A-Za-z_]\w*)\s*\(', code))
    names |= set(re.findall(r'([A-Za-z_]\w*)\s*=\s*function\b', code))
    for params in re.findall(r'\bfunction\b[^(]*\(([^)]*)\)', code):
        for p in params.split(','):
            p = p.strip()
            if re.match(r'^[A-Za-z_]\w*$', p):
                names.add(p)
    for grp in re.findall(r'\blocal\s+([A-Za-z_][\w\s,]*?)(?:=|\n|$)', code):
        for nm in grp.split(','):
            nm = nm.strip()
            if re.match(r'^[A-Za-z_]\w*$', nm):
                names.add(nm)
    for grp in re.findall(r'\bfor\s+([A-Za-z_][\w\s,]*?)\s+in\b', code):
        for nm in grp.split(','):
            nm = nm.strip()
            if re.match(r'^[A-Za-z_]\w*$', nm):
                names.add(nm)
    names |= set(re.findall(r'\bfor\s+([A-Za-z_]\w*)\s*=', code))
    return names


def called_globals(code: str):
    """Bare function-call names in the (stripped) snippet (obj.fn / obj:fn excluded)."""
    return re.findall(r'(?<![\w.:])([A-Za-z_]\w*)\s*\(', code)
