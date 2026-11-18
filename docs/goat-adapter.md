# GOAT adapter

[`scripts/agents/goat/run`](../scripts/agents/goat/run) launches GOAT
(Command Code) from the agent config, so `scripts/agent-launch.sh` can pick a
GOAT lane entry and pass its model id. Run `scripts/agents/goat/run --help` for
the interface, the path and scope checks, the deny rules, and the exit codes.
This page records why it works the way it does.

The example config uses `patch` for the coding and docs lanes and `review` for
the review lanes. `write` is opt-in per lane entry.

## Why patch is the default

`patch` and `review` run the agent read-only, so a change is a diff the
adapter inspects before it touches the tree. Write mode as the default, with
only a post-run gate, was rejected because the gate would then judge a tree
the agent already changed. Paths come from `git apply --numstat` (what git
will touch, not what a header parser might see), and `.git` and
`.commandcode` are matched in any letter case because macOS file systems can
ignore case. Named checks run from a copy of the kit taken before the diff
is applied, under a throwaway `HOME` and a `PATH` of system folders plus the
git and jq found before the run, so a diff cannot rewrite the code that
judges it or put a tool on `PATH`.
Rename and copy targets are marked intent-to-add like new files, and the
run fails if one is still untracked, so the named checks cannot miss a
moved file.

## Why write mode needs a permission bypass

Headless print mode (`-p`) withholds file writes and shell commands unless
permissions are skipped with `--yolo`. A probe with `--permission-mode
dont-ask` plus `allow` rules for the target paths, and with `--tools-enable`,
still got `Tool "write_file" requires permissions`; `--tools-enable` only
re-enables planning-type tools. There is no write-only headless flag.

`deny` rules still win under yolo, so write mode pairs `--yolo` with a
generated deny list. A home-folder read allowlist was considered, but a
blanket `//**` deny also blocks the workspace, so a deny-by-pattern list is
the narrowest form the CLI accepts. Hidden files and `Library` in the home
folder are denied for reads as well as writes: shell startup files and
histories hold secrets too, and a fixed list of credential stores is not
enough.

## Write mode conditions

The maintainer approved write-enabled headless GOAT only under all of these:

1. The launch goes through this adapter, never a direct `--yolo` call.
2. The directory is a disposable worktree so a bad run cannot rewrite the
   main checkout or a default branch: a linked worktree (not the main
   checkout), clean, on a branch that is not `main`, `master`, or the
   remote's default branch (an `origin` without `origin/HEAD` is refused),
   with no `.commandcode` folder (refused in every mode, because project
   settings can carry hooks), no tracked symlink inside a scope, and not
   inside a hidden folder of the home folder. Anything else exits 2 before
   the agent starts.
3. The agent runs under `env -i` so no GitHub token or other caller secret
   reaches it: only a `PATH` of the agent's folder, node's folder, and the
   system folders, a throwaway `HOME` and `TMPDIR` inside the run folder,
   `LANG`, `TERM`, and the GOAT API key.
4. The caller declares the scope as literal repository-relative paths (glob
   characters are refused). After the run the adapter fails closed on
   anything outside that scope or anything that could change git itself:
   the generated `.commandcode` settings must be unchanged, and the only
   other entries allowed are the CLI's own `taste` state; every changed,
   added, deleted, untracked, or newly ignored path is listed; files that
   were already ignored are compared by content hash; a path outside the
   scope, a sibling prefix such as `docsx` for scope `docs`, anything under
   `.git`, a changed git config, hook, info, index, ref, or worktree link
   file, a new, changed, or retargeted file or symlink anywhere in either
   git directory outside the object store (objects/info is still checked),
   a moved git directory, or a moved `HEAD` is a FAIL (exit 1), and the
   tree is left for inspection. After the run the adapter uses only system
   tools and calls git with fsmonitor and hooks off.
5. The adapter never stages, commits, pushes, or opens a pull request. The
   operator does that after the gate passes.

Residual risk: deny rules cannot express "everything outside the scope", and
under yolo a write outside the workspace admits a new root instead of
prompting. The deny list covers the usual places where a planted file would
run later, and the scope gate catches anything inside the worktree, but a
write to another absolute path the caller can write is not caught. Write mode
therefore belongs on a disposable machine, container, or separate user.
