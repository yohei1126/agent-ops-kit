# GOAT adapter

[`scripts/agents/goat/run`](../scripts/agents/goat/run) launches GOAT
(Command Code) from the agent config, so `scripts/agent-launch.sh` can pick a
GOAT lane entry and pass its model id. Run `scripts/agents/goat/run --help` for
the interface and the environment knobs. This page records why it works the
way it does.

## Modes

| Mode | Agent permissions | Result |
| --- | --- | --- |
| `patch` | Read-only | One unified diff, checked and applied to the worktree, then named gate checks |
| `review` | Read-only | A result file whose first line is the `Model:` line |
| `write` | Writes under generated deny rules | Edits in a disposable worktree, then a scope gate |

The example config uses `patch` for the coding and docs lanes and `review` for
the review lanes. `write` is opt-in per lane entry.

`patch` is the default because the agent cannot write: its only output is a
diff, which the adapter checks before applying it to the worktree and then
gates. The adapter accepts only plain `a/` and `b/` headers without quoted
paths, checks every path git itself would touch (`git apply --numstat`), and
refuses an absolute path, a `.` or `..` component, `.git` or `.commandcode` in
any letter case (macOS file systems ignore case), a symlink, or a submodule,
then runs `git apply --check` before `git apply`. The gate runs
from a copy of the kit taken before the diff is applied, under a minimal
environment with the throwaway `HOME` and a `PATH` of system folders plus the
git and jq found before the run, so a diff that edits the gate scripts or
puts a tool on `PATH` cannot run its own code. New files are
marked intent-to-add (the path only, no content staged) so the named checks,
which read tracked files, see them. Nothing is committed.

## Why write mode needs a permission bypass

Headless print mode (`-p`) withholds file writes and shell commands unless
permissions are skipped with `--yolo`. A probe with `--permission-mode
dont-ask` plus `allow` rules for the target paths, and with `--tools-enable`,
still got `Tool "write_file" requires permissions`; `--tools-enable` only
re-enables planning-type tools. There is no write-only headless flag.

What does narrow a `--yolo` run: `deny` rules win in every mode, including
yolo. So write mode, and only write mode, pairs `--yolo` with a generated
`.commandcode/settings.local.json` that denies `Shell`, web fetches, every MCP
tool, edits to `.git` and `.commandcode`, reads and edits of the worktree's
git directories (absolute `//` rules), edits of hidden files and folders,
`bin`, and `Library` in the caller's home, edits of `/usr/local` and `/opt/homebrew`, and
reads of every hidden file and folder and of `Library` in the caller's home
(shell startup files and histories hold secrets too, so a fixed list of
credential stores is not enough). A deny of every
absolute path (`//**`) is not possible: it also blocks the workspace. A test fails if any other
kit script passes `--yolo`.

## Write mode conditions

The maintainer approved write-enabled headless GOAT only under all of these:

1. The launch goes through this adapter, never a direct `--yolo` call.
2. The directory is a disposable worktree: a linked worktree (not the main
   checkout), clean, on a branch that is not `main`, `master`, or the
   remote's default branch (an `origin` without `origin/HEAD` is refused),
   with no `.commandcode` folder (refused in every mode, because project
   settings can carry hooks), no tracked symlink inside a scope, and not
   inside a hidden folder of the home folder. Anything else exits 2 before the
   agent starts.
3. The agent runs under `env -i` with only a `PATH` of the agent's folder,
   node's folder, and the system folders, a throwaway `HOME` and `TMPDIR`
   inside the run folder, `LANG`, `TERM`, and the GOAT API key. No GitHub
   token or other secret reaches it.
4. The caller declares the scope (literal repository-relative paths; glob
   characters are refused). After the run
   the adapter checks `.commandcode`: the generated settings must be
   unchanged and the only other entries allowed are the CLI's own `taste`
   state; anything else fails the run and the folder is left for inspection.
   It then lists every changed, added, deleted, untracked, or newly ignored
   path, and compares files that were already ignored before the run by
   content hash, so a rewrite or delete of one outside the scope fails too. A path outside the scope, a
   sibling prefix such as `docsx` for scope `docs`, anything under `.git`, a
   changed git config, hook, info, index, ref, or worktree link file
   (compared by content hash), a moved git directory, or a moved `HEAD` is a
   FAIL (exit
   1), and the tree is left for inspection. After the run the adapter uses
   only system tools and calls git with fsmonitor and hooks off.
5. The adapter never stages, commits, pushes, or opens a pull request. The
   operator does that after the gate passes.

Residual risk: deny rules cannot express "everything outside the scope", and
under yolo a write outside the workspace admits a new root instead of
prompting. The deny list covers the usual places where a planted file would
run later, and the scope gate catches anything inside the worktree, but a
write to another absolute path the caller can write is not caught. Write mode
therefore belongs on a disposable machine, container, or separate user. When
the agent exits non-zero, its stderr tail is printed with the API key value
replaced by `<redacted>`, and patch or review output that contains the key is
refused without being printed.

## Model line

Review mode writes `Model: <line>` as the first line of the result. The caller
sets the full line in `GOAT_MODEL_LINE`, for example `Example Model
(example/model-1) (Command Code / GOAT)`; without it the line is the model id
followed by `(Command Code / GOAT)`. The launcher does not export it, so the
environment of other adapters stays unchanged.

## Fail closed

A missing API key, a missing or unknown mode, a missing model, a path that is
not a git worktree, a symlinked worktree or brief, no diff, more than one diff,
or a diff that fails `git apply --check` exits 2 and nothing is applied. An
agent failure, a failing gate check, or a scope FAIL exits 1. The key value is
never printed; `--dry-run` shows it as `<set>` or `<missing>`.
