#!/bin/bash
# No verifier: report success so the trial completes. Model patch is captured by the
# task.toml [[verifier.collect]] hook, not here.
mkdir -p /logs/verifier
echo 1 > /logs/verifier/reward.txt
