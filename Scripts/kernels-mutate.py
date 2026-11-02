#!/usr/bin/env python3
"""Mutation testing of the C kernels' checks: each mutant plants one defect a kernel could plausibly have (an off-by-one bound, a
wrong constant, a dropped validity test, a target-attribute slip, a broken constant-time loop), in a copy of the tree, and the
mutant's check must fail on it. A mutant that survives is a hole in the checks.

    Scripts/kernels-mutate.py                 every mutant of every file in Scripts/mutants
    Scripts/kernels-mutate.py NAME...         only these (a mutant's name, or a file's stem: codec, kernels, crypto)

Format of Scripts/mutants/*.txt: mutants separated by a line `---`; `name:`, `file:` and the optional `check:` (a shell command run
at the copy's root; default `bash Scripts/kernels-check.sh`) take one line; the text after `old:` up to `new:`, and after `new:`
up to the separator, is literal and may span lines. `old` must occur exactly once in the file. Exit 0 when every mutant was killed.
"""
import pathlib, shutil, subprocess, sys, tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
COPY = ["Package.swift", "Scripts", "Benchmarks/CKernels", "Sources/CAemiKernels", "Sources/CAemiCPU", "Sources/CAemiArgon2"]


def mutants():
    result = []
    for path in sorted((ROOT / "Scripts/mutants").glob("*.txt")):
        for block in path.read_text().split("\n---\n")[1:]:
            head, _, rest = block.partition("\nold:\n")
            old, _, new = rest.partition("\nnew:\n")
            fields = dict(line.split(": ", 1) for line in head.splitlines())
            fields["old"], fields["new"], fields["group"] = old, new.rstrip("\n"), path.stem
            fields.setdefault("check", "bash Scripts/kernels-check.sh")
            result.append(fields)
    return result


def main():
    only = set(sys.argv[1:])
    survived = []
    for mutant in mutants():
        if only and mutant["name"] not in only and mutant["group"] not in only:
            continue
        with tempfile.TemporaryDirectory() as scratch:
            tree = pathlib.Path(scratch)
            for part in COPY:
                source = ROOT / part
                (tree / part).parent.mkdir(parents=True, exist_ok=True)
                if source.is_dir():
                    shutil.copytree(source, tree / part)
                else:
                    shutil.copy(source, tree / part)
            target = tree / mutant["file"]
            original = target.read_text()
            if original.count(mutant["old"]) != 1:
                print(f"[FAIL] {mutant['name']}: `old` occurs {original.count(mutant['old'])} times in {mutant['file']}")
                return 2
            target.write_text(original.replace(mutant["old"], mutant["new"]))
            run = subprocess.run(mutant["check"], shell=True, cwd=tree, capture_output=True, text=True)
            if run.returncode == 0:
                survived.append(mutant["name"])
                print(f"[SURVIVED] {mutant['name']}", flush=True)
            else:
                print(f"[killed] {mutant['name']}", flush=True)
    print(f"{len(survived)} mutant(s) survived" + (f": {', '.join(survived)}" if survived else ""))
    return 1 if survived else 0


if __name__ == "__main__":
    sys.exit(main())
