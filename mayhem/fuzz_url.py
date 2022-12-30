#!/usr/bin/env python3

import atheris
import sys
import fuzz_helpers

with atheris.instrument_imports(include=['rfc3986']):
    from rfc3986 import urlparse, uri_reference

from rfc3986.exceptions import InvalidPort

def TestOneInput(data):
    fdp = fuzz_helpers.EnhancedFuzzedDataProvider(data)
    try:
        if fdp.ConsumeBool():
            urlparse(fdp.ConsumeRemainingString())
        else:
            uri_reference(fdp.ConsumeRemainingString())
    except InvalidPort:
        return -1

def main():
    atheris.Setup(sys.argv, TestOneInput)
    atheris.Fuzz()


if __name__ == "__main__":
    main()
