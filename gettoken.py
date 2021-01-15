import json
import sys

token_data = json.load(sys.stdin)
print(token_data["access_token"])
