import json,socket,sys
# 用法：big-request-probe.py <browser 資料夾> <中文字數>：送一個很長的 ls 請求（欄位塞滿中文），印伺服器回的 ok
d=sys.argv[1]; n=int(sys.argv[2])
token=open(d+"/token").read().strip(); path=open(d+"/socket").read().strip()
s=socket.socket(socket.AF_UNIX); s.settimeout(30); s.connect(path)
try:
    s.sendall((json.dumps({"cmd":"ls","token":token,"pad":"中"*n}, ensure_ascii=False)+"\n").encode())
    b=bytearray()
    while True:
        c=s.recv(65536)
        if not c: break
        b.extend(c)
    r=json.loads(b.decode("utf-8")); print("ok=%s" % r.get("ok"), r.get("error",""))
except Exception as e:
    print("ok=False", type(e).__name__)
finally:
    s.close()
