#!/usr/bin/env bash
# Usage: tools/ci.sh [run_id] [wait]  — shows job/step status of the latest (or given) CI run.
set -euo pipefail
T=$(cat /root/.pdf995_github_token); API=https://api.github.com/repos/osama-alzumar/pdf995
RUN=${1:-$(curl -s -H "Authorization: Bearer $T" "$API/actions/runs?per_page=1" | python3 -c "import json,sys;print(json.load(sys.stdin)['workflow_runs'][0]['id'])")}
if [ "${2:-}" = wait ]; then
  while [ "$(curl -s -H "Authorization: Bearer $T" "$API/actions/runs/$RUN" | python3 -c "import json,sys;print(json.load(sys.stdin)['status'])")" != completed ]; do sleep 30; done
fi
curl -s -H "Authorization: Bearer $T" "$API/actions/runs/$RUN/jobs" | python3 -c "
import json,sys
for j in json.load(sys.stdin)['jobs']:
    print(j['id'], j['name'], j['status'], j['conclusion'])
    for s in j['steps']:
        if s['conclusion'] not in ('success','skipped'): print('   ', s['name'], s['status'], s['conclusion'])
"
