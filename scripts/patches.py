#!/usr/bin/env python3
"""Moved to tools/patches.py (LNPANDY/NX2Apple#214). This forwarder keeps the old command working until the committed tree goes."""
import os
import runpy

runpy.run_path(os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir, 'tools', 'patches.py'), run_name='__main__')
