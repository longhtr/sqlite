#!/usr/bin/env python3
"""Generate deterministic bounded statement scaffold fixtures."""
from pathlib import Path
import json,sys
ROOT=Path(__file__).resolve().parent.parent;OUT=ROOT/'tests/fixtures/statement'
def main():
 out=Path(sys.argv[1]).resolve() if len(sys.argv)>1 else OUT;out.mkdir(parents=True,exist_ok=True)
 api=json.loads((ROOT/'upstream/api-manifest.json').read_text())
 symbols=sorted(e['symbol'] for e in api['declarations'] if e['phase']=='phase-12')
 doc={'schema_version':1,'phase':'phase-12-statement-api','profile':'native-program-statement-lifecycle-v1','programs':[{'name':'bindings','parameters':[':integer','@text','$blob','?4'],'columns':['integer','text','blob','utf16']},{'name':'error','result_code':2067}],'implemented_symbols':symbols,'implemented_symbol_count':len(symbols),'canonical_header_assertions':60,'public_prepare_profile':'absent-until-native-frontend-codegen-phase-13','encodings':['utf-8','utf-16le-native-target']}
 (out/'manifest.json').write_text(json.dumps(doc,indent=2)+'\n');print('generate-statement-fixtures: wrote 2 programs')
if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
