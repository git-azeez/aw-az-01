"""Stream safe Terraform progress while retaining private diagnostic output."""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parent
progress = re.compile(r'^aws_.*: (Creating|Creation complete|Modifying|Modifications complete|Destroying|Destruction complete|Still (creating|modifying|destroying))')
with open(sys.argv[1], 'a') as log:
    process = subprocess.Popen(['terraform', f'-chdir={root / "infra"}', *sys.argv[2:]],
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
    for line in process.stdout:
        log.write(line)
        log.flush()
        if progress.match(line) or line.startswith(('Apply complete!', 'Destroy complete!')):
            print(line.rstrip(), flush=True)
    sys.exit(process.wait())
