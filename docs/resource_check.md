# Resource check

Commands for checking what this project consumes, on the cluster and on the Mac.

All commands below were verified against a running `k3d-platform` cluster on OrbStack.

**If you just want one number, skip to [Summary](#summary-one-command) at the bottom.**
The sections in between are for when you need to know *which* thing is eating the budget.

## Preflight: confirm which daemon you're on

These numbers are meaningless if the tooling is pointed at Docker Desktop instead of
OrbStack. Check first:

```bash
k3d node list --verbose 2>&1 | grep -oE 'InfoName:[^}]*'
```

Expect `InfoName:orbstack`. If you get `InfoName:docker-desktop`, start OrbStack and run
`docker context use orbstack` before trusting anything below.

## CPU and memory

`docker stats` and `kubectl top` both report CPU and memory together, so there is no
separate memory command.

### Per container

```bash
docker ps -q --filter name=k3d-platform \
  | xargs docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}'
```

```
NAME                    CPU %     MEM USAGE / LIMIT
k3d-platform-serverlb   0.00%     8.883MiB / 7.817GiB
k3d-platform-agent-0    19.23%    776.2MiB / 7.817GiB
k3d-platform-server-0   11.71%    799.4MiB / 7.817GiB
```

### Per pod

Requires metrics-server, which this cluster already runs.

```bash
kubectl --context k3d-platform top pods -A --sort-by=cpu
kubectl --context k3d-platform top nodes
```

```
NAMESPACE     NAME                              CPU(cores)   MEMORY(bytes)
argocd        argocd-application-controller-0   16m          162Mi
kube-system   metrics-server-...                15m           46Mi
kube-system   coredns-...                       13m           40Mi
```

### What the VM is allowed, and what it costs the Mac

```bash
docker info --format 'VM: {{.NCPU}} CPUs, {{.MemTotal}} bytes RAM'

ps ax -o %cpu=,rss=,comm= | grep "OrbStack Helper" \
  | awk '{printf "OrbStack VM host: %.1f%% CPU, %.2f GB RSS\n", $1, $2/1024/1024}'
```

```
VM: 8 CPUs, 8393605120 bytes RAM
OrbStack VM host: 34.7% CPU, 1.48 GB RSS
```

The host RSS is usually *lower* than the sum of what the containers report. OrbStack
returns unused guest memory to macOS, so the VM's footprint tracks real usage rather than
the 8 GB it is allowed.

## Storage

### Docker level

```bash
docker system df          # add -v for the per-image and per-volume breakdown
```

```
TYPE            TOTAL     ACTIVE    SIZE      RECLAIMABLE
Images          6         2         963.5MB   523.8MB (54%)
Containers      3         3         1.081MB   0B (0%)
Local Volumes   9         9         4.661GB   0B (0%)
Build Cache     0         0         0B        0B
```

### Cluster level

```bash
kubectl --context k3d-platform get pvc -A
```

```
NAMESPACE   NAME              STATUS   CAPACITY   STORAGECLASS
platform    data-postgres-0   Bound    2Gi        local-path
```

### Inside the k3d nodes

```bash
for n in k3d-platform-server-0 k3d-platform-agent-0; do
  printf '%-24s ' "$n"; docker exec "$n" df -h / | tail -1
done
```

```
k3d-platform-server-0    overlay  43G  5.7G  38G  14% /
k3d-platform-agent-0     overlay  43G  5.7G  38G  14% /
```

Both nodes report the same figures because they share the VM's filesystem.

### What OrbStack actually consumes on the Mac's disk

```bash
du -sh ~/Library/Group\ Containers/HUAQ24HBR6.dev.orbstack
```

```
5.6G    /Users/<you>/Library/Group Containers/HUAQ24HBR6.dev.orbstack
```

## Gotchas

**Use `du`, never `ls -lh`, for the OrbStack disk image.** It is sparse, so the two
disagree by two orders of magnitude:

```bash
ls -lh ~/Library/Group\ Containers/HUAQ24HBR6.dev.orbstack/data/data.img.raw   # 460G, apparent
du  -h ~/Library/Group\ Containers/HUAQ24HBR6.dev.orbstack/data/data.img.raw   # 5.6G, actual
```

**`docker stats` lies when given an empty container list.** With no arguments it lists
every running container, so this form silently widens to "everything on the daemon" when
the cluster is down:

```bash
# avoid: shows all containers, with no error, if the cluster is not running
docker stats --no-stream --format '...' $(docker ps -q --filter name=k3d-platform)
```

The `xargs` form used above is correct instead, because BSD xargs on macOS does not run
the command at all when its input is empty. `docker stats` has no `--filter` flag, so
piping container IDs is the only option.

**Do not refactor the pipeline into a variable.** This is a zsh-specific trap. zsh does
not word-split an unquoted `$var`, so docker receives one newline-joined blob and fails
with `Error response from daemon: page not found`:

```bash
# broken in zsh
ids=$(docker ps -q --filter name=k3d-platform)
docker stats --no-stream --format '...' $ids
```

Use `${=ids}` if you really need the variable, or keep the pipeline.

**Reclaiming space.** `docker image prune` clears the dangling images counted as
reclaimable above. Avoid `docker system prune -a`, which would delete the k3s and ArgoCD
images the cluster needs to restart and force a full re-pull.

---

Example output above is a snapshot and will not match your run. The shapes and column
headers are what to compare against.

## Summary: one command

Everything above, condensed. Shows what the VM was given and what percentage of it the
project is currently using. Works in both bash and zsh, and needs no images beyond what
the cluster already runs.

```bash
CLUSTER=platform

ids=$(docker ps -q --filter "name=k3d-$CLUSTER")
if [ -z "$ids" ]; then
  echo "k3d-$CLUSTER has no running containers. Start it with 'gmake resume'."
else
  ncpu=$(docker info --format '{{.NCPU}}')
  mem=$(docker info --format '{{.MemTotal}}')
  disk=$(docker exec "k3d-$CLUSTER-server-0" df -B1 / | tail -1)
  rss=$(ps ax -o rss=,comm= | grep "OrbStack Helper" | awk '{print $1}')
  hostdisk=$(du -sk ~/Library/Group\ Containers/HUAQ24HBR6.dev.orbstack | cut -f1)

  echo "$ids" | xargs docker stats --no-stream --format '{{.CPUPerc}}|{{.MemPerc}}' \
  | awk -F'|' -v ncpu="$ncpu" -v mem="$mem" -v disk="$disk" -v rss="$rss" -v hd="$hostdisk" '
    { gsub(/%/,""); c+=$1; m+=$2 }
    END {
      split(disk, d, /[ \t]+/); dtot=d[2]; dused=d[3]; g=1073741824
      printf "\nOrbStack VM: allocated vs in use\n\n"
      printf "%-8s %13s %15s %9s\n", "", "ALLOCATED", "IN USE", "USED"
      printf "%-8s %13s %15s %8.1f%%\n", "CPU",    ncpu " cores",              sprintf("%.2f cores", c/100), c/ncpu
      printf "%-8s %13s %15s %8.1f%%\n", "Memory", sprintf("%.2f GiB", mem/g), sprintf("%.2f GiB", m/100*mem/g), m
      printf "%-8s %13s %15s %8.1f%%\n", "Disk",   sprintf("%.2f GiB", dtot/g),sprintf("%.2f GiB", dused/g), dused/dtot*100
      printf "\ncost to macOS: %.2f GB RAM, %.2f GB disk\n\n", rss/1048576, hd/1048576
    }'
fi
```

```
OrbStack VM: allocated vs in use

             ALLOCATED          IN USE      USED
CPU            8 cores      0.87 cores     10.9%
Memory        7.82 GiB        1.56 GiB     19.9%
Disk         41.38 GiB        5.63 GiB     13.6%

cost to macOS: 1.17 GB RAM, 5.64 GB disk
```

Reading it:

- **ALLOCATED** is what OrbStack gives the VM, adjustable in OrbStack Settings under
  Resources.
- **IN USE** and **USED %** are this project's three k3d containers only, measured against
  that allocation.
- **cost to macOS** is the separate question of what the VM costs the host: resident
  memory of the VM process, and actual (not apparent) disk.

Two caveats:

- **CPU is an instantaneous sample and swings hard.** Repeated runs seconds apart gave
  3.6%, 10.9%, and briefly over 12%. Treat one reading as noise. Memory and disk are
  stable.
- **Disk "allocated" is soft.** OrbStack grows the VM filesystem on demand inside a sparse
  image, so 41.38 GiB is its size right now, not a ceiling you are approaching.

Worth saving as a shell function rather than pasting each time:

```bash
# add to ~/.zshrc
lfi-resources() { bash ~/path/to/lfi-resources.sh; }
```

