import json
import sys
import base64

secret_data = json.load(sys.stdin)
print(base64.b64decode(secret_data["payload"]["data"]))
