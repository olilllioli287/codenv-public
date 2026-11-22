#!/usr/bin/env python3
"""Compare app-side LidSim/TestHarness observations against the spec contract."""
import json,sys
from pathlib import Path

def compare(expected, actual, path):
    errors=[]
    if isinstance(expected,dict):
        if not isinstance(actual,dict): return [f"{path}: 預期 object，實際 {actual!r}"]
        for k,v in expected.items(): errors += compare(v,actual.get(k),f"{path}.{k}")
    elif isinstance(expected,list):
        if not isinstance(actual,list) or len(actual)!=len(expected): return [f"{path}: 預期 {expected!r}，實際 {actual!r}"]
        for i,(e,a) in enumerate(zip(expected,actual)): errors += compare(e,a,f"{path}[{i}]")
    elif type(expected)!=type(actual) or expected!=actual:
        errors.append(f"{path}: 預期 {expected!r}，實際 {actual!r}")
    return errors

if __name__=='__main__':
    if len(sys.argv) != 3:
        print('用法：awake-closed-probe.py <題號> <掛鉤輸出.json>')
        sys.exit(2)
    case, filename=sys.argv[1:]
    output_path=Path(filename)
    if not output_path.is_file():
        print(f'失敗：{case}.output: 找不到掛鉤輸出：{filename}')
        sys.exit(1)
    try:
        contract=json.loads(Path(__file__).with_name('awake-closed-contract.json').read_text())
        data=json.loads(output_path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        print(f'失敗：{case}.output: 無法讀取 JSON：{type(error).__name__}')
        sys.exit(1)
    if not isinstance(contract,dict) or case not in contract:
        print(f'失敗：{case}.contract: 找不到題目契約')
        sys.exit(2)
    if not isinstance(data,dict):
        print(f'失敗：{case}.output: 預期 JSON object')
        sys.exit(1)
    observed=data.get('observed')
    if isinstance(observed,dict) and observed.get('probeError'):
        print(f"失敗：{case}.probeError: 掛鉤執行失敗：{observed['probeError']}")
        sys.exit(1)
    errors=compare({'caseId':case,'schemaVersion':1,'observed':contract[case]['expected']},data,case)
    for error in errors: print('失敗：'+error)
    if not errors: print(f'通過：{case}')
    sys.exit(bool(errors))
