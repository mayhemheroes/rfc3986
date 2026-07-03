#!/usr/bin/env python3
"""Atheris fuzz harness for rfc3986.

Exercises the public URI/IRI parsing + validation + normalization API on
arbitrary input. Atheris instruments the imported rfc3986 modules (coverage),
so libFuzzer drives the parser toward new code paths.

Run modes (driven by the compiled launcher `rfc3986_fuzzer` / `-standalone`):
  * fuzzing      — `python3 fuzz_rfc3986.py [libFuzzer args]`
  * single input — `python3 fuzz_rfc3986.py <file>` (libFuzzer runs it once)
"""
import sys

import atheris

# Instrument the library under test so the fuzzer gets coverage feedback.
with atheris.instrument_imports():
    import rfc3986
    from rfc3986 import exceptions as rfc3986_exceptions


def TestOneInput(data: bytes) -> None:
    fdp = atheris.FuzzedDataProvider(data)
    text = fdp.ConsumeUnicodeNoSurrogates(atheris.ALL_REMAINING)
    try:
        ref = rfc3986.uri_reference(text)
        # Validation must never raise on a well-formed reference object.
        ref.is_valid()
        ref.is_valid(require_scheme=True, require_authority=True)
        # Normalization + round-trip through unsplit().
        ref.normalize().unsplit()
        # The urlparse() compatibility shim.
        rfc3986.urlparse(text)
        # IRI handling (covers the unicode path).
        rfc3986.iri_reference(text)
        # The top-level validity convenience function.
        rfc3986.is_valid_uri(text)
    except rfc3986_exceptions.RFC3986Exception:
        # Library-defined errors are expected for malformed input.
        pass
    except (UnicodeError, ValueError):
        # Encoding/value errors from pathological unicode are not defects.
        pass


def main() -> None:
    atheris.Setup(sys.argv, TestOneInput)
    atheris.Fuzz()


if __name__ == "__main__":
    main()
