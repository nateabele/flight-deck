#!/bin/bash
# Run the old qartez-guard and `fdindex guard` on the same PreToolUse inputs in scratch repos and
# print a parity table (exit status and stdout must match; stderr is shown where it differs).
#
#   guard-parity.sh [path/to/fdindex]     (needs ~/.local/bin/qartez-guard and ~/.local/bin/qartez)
#
# Nothing outside a temp directory is touched: qartez runs with a temp HOME, fdindex with a temp
# store and socket. The scratch repos are built here, indexed by both engines, then compared.
set -u
FD=$(realpath "${1:-$(dirname "$0")/../target/release/fdindex}")
OLD=$HOME/.local/bin/qartez-guard
QZ=$HOME/.local/bin/qartez
W=$(mktemp -d /tmp/fdparity.XXXXXX); trap 'ls $W/store/daemon.pid >/dev/null 2>&1 && "$FD" --store $W/store --socket $W/s.sock stop >/dev/null 2>&1; rm -rf "$W"' EXIT
export HOME_REAL=$HOME
mkdir -p $W/home $W/store
fdx() { "$FD" --store $W/store --socket $W/s.sock "$@"; }

mkrepo() { # name, importer count
  local d=$W/$1; mkdir -p $d/src; cd $d; git init -q .
  echo "export function core(){return 1}" > src/core.ts
  echo "export const leaf = 1" > src/leaf.ts
  for i in $(seq 1 $2); do echo "import { core } from './core'; export const u$i = () => core()" > src/u$i.ts; done
  git add -A; git -c user.email=a@b -c user.name=x commit -qm init
  HOME=$W/home $QZ --root $d stats >/dev/null 2>&1
  fdx hello >/dev/null; fdx build $d --wait-ms 60000 >/dev/null
}
mkrepo small 6   # core: PageRank high, blast 6 (under 10)
mkrepo big 20    # core: PageRank high, blast 20
rm -rf $W/bare; mkdir -p $W/bare/src; echo "export const x=1" > $W/bare/src/x.ts; (cd $W/bare; git init -q .; git add -A; git -c user.email=a@b -c user.name=x commit -qm i)

json() { # tool file cwd
  printf '{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"%s","tool_input":{"file_path":"%s","pattern":"x"},"cwd":"%s"}' "$1" "$2" "$3"
}
ackfor() { # root rel age_secs  -> an ack file the way either guard wants it (fnv1a64 name, mtime backdated)
  python3 - "$1" "$2" "$3" <<'PY'
import sys,os,time
root,rel,age=sys.argv[1],sys.argv[2],int(sys.argv[3])
h=0xcbf29ce484222325
for b in rel.encode(): h=((h^b)*0x100000001b3)&0xffffffffffffffff
d=os.path.join(root,'.qartez','acks'); os.makedirs(d,exist_ok=True)
p=os.path.join(d,'%016x'%h); open(p,'w').write('%d\n%s\n'%(int(time.time())-age,rel)); t=time.time()-age; os.utime(p,(t,t))
PY
}
clearacks() { rm -rf $W/small/.qartez/acks $W/big/.qartez/acks; }

printf '| case | qartez-guard | fdindex guard | parity |\n|---|---|---|---|\n'
row() { # label stdin-text [env assignments...] -- [flags...]
  local label=$1 input=$2; shift 2; local envs=(); while [ "${1:-}" != "--" ] && [ $# -gt 0 ]; do envs+=("$1"); shift; done; shift
  local o e x; o=$(echo "$input" | env ${envs[@]+"${envs[@]}"} "$OLD" "$@" 2>$W/e1); x1=$?
  n=$(echo "$input" | env ${envs[@]+"${envs[@]}"} "$FD" --store $W/store --socket $W/s.sock guard "$@" 2>$W/e2); x2=$?
  short() { if [ -z "$1" ]; then echo "allow (silent)"; else echo "$1" | python3 -c "import sys,json;r=json.load(sys.stdin)['hookSpecificOutput'];print('deny: '+r['permissionDecisionReason'][:70].replace('|','/')+'…')" 2>/dev/null || echo "$1"; fi; }
  local same=NO; [ "$o" = "$n" ] && [ $x1 = $x2 ] && same=identical
  if [ $same = NO ]; then
    # Each engine computes its own PageRank (plain power iteration here, qartez's own variant there),
    # so the third digit of a value and the hot-symbol ranks can differ; the decision and wording may not.
    mask() { sed -E 's/PageRank [0-9.]+ >=/PageRank N >=/; s/ Hot symbols.*//' <<<"$1"; }
    [ "$(mask "$o")" = "$(mask "$n")" ] && [ $x1 = $x2 ] && same="same decision and wording; PageRank/hot-symbol numbers differ in digits"
  fi
  printf '| %s | exit %s, %s | exit %s, %s | %s |\n' "$label" $x1 "$(short "$o")" $x2 "$(short "$n")" "$same"
}
S=$W/small; B=$W/big
clearacks
row "Glob in indexed repo"            "$(json Glob '' $S)" --
row "Grep in indexed repo"            "$(json Grep '' $S)" --
row "Glob, repo with no index"        "$(json Glob '' $W/bare)" --
row "Glob from a subdirectory"        "$(json Glob '' $S/src)" --
row "Edit hub (PageRank only)"        "$(json Edit $S/src/core.ts $S)" --
row "Edit leaf (PageRank 0.076)"      "$(json Edit $S/src/leaf.ts $S)" --
row "Edit hub, relative path"         "$(json Edit src/core.ts $S)" --
row "Edit hub from another cwd"       "$(json Edit $S/src/core.ts /tmp)" --
row "Edit hub (PageRank + blast 20)"  "$(json Edit $B/src/core.ts $B)" --
row "MultiEdit hub"                   "$(json MultiEdit $S/src/core.ts $S)" --
row "Write existing hub"              "$(json Write $S/src/core.ts $S)" --
row "Write new file"                  "$(json Write $S/src/new.ts $S)" --
row "Edit unindexed README"           "$(json Edit $S/README.md $S)" --
row "Gemini replace on hub"           "$(json replace $S/src/core.ts $S)" --
row "Gemini grep_search"              "$(json grep_search '' $S)" --
row "Read of source"                  "$(json Read $S/src/core.ts $S)" --
row "Bash"                            "$(json Bash '' $S)" --
row "empty stdin"                     "" --
row "garbage stdin"                   "garbage" --
row "pagerank-min 0.9 (blast 6<10)"   "$(json Edit $S/src/core.ts $S)" -- --pagerank-min 0.9
row "blast-min 6, pagerank-min 0.9"   "$(json Edit $S/src/core.ts $S)" -- --pagerank-min 0.9 --blast-min 6
row "blast-min 7, pagerank-min 0.9"   "$(json Edit $S/src/core.ts $S)" -- --pagerank-min 0.9 --blast-min 7
row "env QARTEZ_GUARD_PAGERANK_MIN=0.9" "$(json Edit $S/src/core.ts $S)" QARTEZ_GUARD_PAGERANK_MIN=0.9 --
row "QARTEZ_GUARD_DISABLE=1"          "$(json Edit $S/src/core.ts $S)" QARTEZ_GUARD_DISABLE=1 --
row "QARTEZ_GUARD_DISABLE=0"          "$(json Edit $S/src/core.ts $S)" QARTEZ_GUARD_DISABLE=0 --
ackfor $S src/core.ts 0;   row "fresh ack (0 s)"            "$(json Edit $S/src/core.ts $S)" --
ackfor $S src/core.ts 598; row "ack 598 s old"              "$(json Edit $S/src/core.ts $S)" --
ackfor $S src/core.ts 650; row "ack 650 s old (past TTL)"   "$(json Edit $S/src/core.ts $S)" --
ackfor $S src/core.ts 100; row "ack 100 s, --ack-ttl-secs 50"  "$(json Edit $S/src/core.ts $S)" -- --ack-ttl-secs 50
row "ack 100 s, env ack ttl 150"      "$(json Edit $S/src/core.ts $S)" QARTEZ_GUARD_ACK_TTL_SECS=150 --
clearacks
# fdindex's own acks, written by its impact tool, satisfy the old guard too.
(cd $S && fdx impact src/core.ts >/dev/null)
row "ack written by fdindex impact"   "$(json Edit $S/src/core.ts $S)" --
printf '\nCross-check: the ack fdindex impact wrote is the name and content the old guard reads: %s\n' "$(ls $S/.qartez/acks | head -1)"
# Daemon down: fdindex allows and says so; the old guard has no daemon to lose.
fdx stop >/dev/null 2>&1
n=$(json Edit $B/src/core.ts $B | "$FD" --store $W/store --socket $W/s.sock guard 2>$W/e3); x=$?
printf '\nDaemon down: fdindex guard exit %s, stdout %s, stderr: %s\n' $x "${n:-empty}" "$(cat $W/e3)"
