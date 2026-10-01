#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path

state_path = Path(os.environ["FAKE_CRYPTSETUP_STATE"])
state = json.loads(state_path.read_text())
arguments = sys.argv[1:]
command = arguments[0]
key_file = next((a.split("=", 1)[1] for a in arguments if a.startswith("--key-file=")), None)
positional = [a for a in arguments[1:] if not a.startswith("--")]
call = {"argv": arguments}
if key_file:
    call["key_file_content"] = Path(key_file).read_text()
json_file = next((a.split("=", 1)[1] for a in arguments if a.startswith("--json-file=")), None)
if json_file:
    call["json_file_content"] = Path(json_file).read_text()
state["calls"].append(call)

exit_code = 0
if command == "luksDump":
    print(json.dumps({"keyslots": {str(n): {"type": "luks2"} for n in state["keyslots"]}}))
elif command == "luksUUID":
    print(state["uuids"][positional[0]])
elif command == "luksAddKey":
    if call["key_file_content"] != state["existing_passphrase"]:
        exit_code = 2
    else:
        new_key_content = Path(positional[-1]).read_text()
        call["new_key_content"] = new_key_content
        slot = min(set(range(32)) - {int(n) for n in state["keyslots"]})
        state["keyslots"][str(slot)] = new_key_content
elif command == "token":
    if state["fail_token_import"]:
        exit_code = 1
        print("token import refused")
elif command == "luksKillSlot":
    slot = arguments[-1]
    if state["keyslots"].get(slot) != call["key_file_content"]:
        exit_code = 2
    else:
        del state["keyslots"][slot]
else:
    exit_code = 99

state_path.write_text(json.dumps(state))
sys.exit(exit_code)
