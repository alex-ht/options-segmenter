#!/usr/bin/env python3
import sys

for line in sys.stdin:
    columns = line.strip('\n').split(' ');
    for idx in range(2, len(columns), 3):
        columns[idx] = " ".join([ "<ANY>" for c in columns[idx] ])
    print(" ".join(columns))
