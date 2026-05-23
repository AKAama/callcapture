#!/bin/bash
# Stream CallCapture OSLog (subsystem com.callcapture.app).
# Used for live debugging sessions.
exec log stream --level debug --style compact \
  --predicate 'subsystem == "com.callcapture.app"'
