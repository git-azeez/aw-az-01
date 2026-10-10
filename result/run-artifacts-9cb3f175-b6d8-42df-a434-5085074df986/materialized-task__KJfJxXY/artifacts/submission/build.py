import os
d = os.path.dirname(os.path.abspath(__file__))
schema = open(f"{d}/src/schema.sql").read().rstrip("\n")
conv = open(f"{d}/src/converge.py").read().rstrip("\n")
for name in ("deploy", "destroy"):
    t = open(f"{d}/src/{name}.sh.tpl").read()
    t = t.replace("@@SCHEMA@@", schema).replace("@@CONVERGE@@", conv)
    p = f"{d}/{name}.sh"
    open(p, "w").write(t)
    os.chmod(p, 0o755)
print("built")
