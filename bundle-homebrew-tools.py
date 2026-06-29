#!/usr/bin/env python3
import os
import shutil
import subprocess
import sys
from glob import glob
from pathlib import Path


SYSTEM_PREFIXES = (
    "/System/Library/",
    "/usr/lib/",
)


def run(args):
    return subprocess.run(args, check=True, text=True, capture_output=True).stdout


def which(name):
    path = shutil.which(name)
    if not path:
        raise SystemExit(f"未找到 {name}。请先在构建机安装对应 Homebrew formula。")
    return Path(path).resolve()


def otool_deps(path):
    output = run(["otool", "-L", str(path)])
    deps = []
    for line in output.splitlines()[1:]:
        line = line.strip()
        if not line:
            continue
        deps.append(line.split(" ", 1)[0])
    return deps


def is_external_dependency(path, loader_dir=None):
    if path.startswith(SYSTEM_PREFIXES):
        return False
    if path.startswith("@") and not path.startswith("@rpath/"):
        if not path.startswith("@loader_path/"):
            return False
    return resolve_dependency(path, loader_dir=loader_dir) is not None


def resolve_dependency(path, loader_dir=None):
    if path.startswith(SYSTEM_PREFIXES):
        return None
    if path.startswith("/opt/homebrew/") and Path(path).exists():
        return Path(path).resolve()
    if path.startswith("@loader_path/") and loader_dir is not None:
        suffix = path.removeprefix("@loader_path/")
        candidate = Path(loader_dir) / suffix
        if candidate.exists():
            return candidate.resolve()
    if path.startswith("@rpath/"):
        suffix = path.removeprefix("@rpath/")
        candidates = [
            f"/opt/homebrew/lib/{suffix}",
            f"/opt/homebrew/opt/*/lib/{suffix}",
            f"/opt/homebrew/Cellar/*/*/lib/{suffix}",
        ]
        for pattern in candidates:
            for match in glob(pattern):
                if Path(match).exists():
                    return Path(match).resolve()
    return None


def copy_binary(src, dst):
    src = Path(src).resolve()
    shutil.copy2(src, dst)
    os.chmod(dst, 0o755)


def install_name_change(target, old, new):
    subprocess.run(["install_name_tool", "-change", old, new, str(target)], check=False)


def install_name_id(target, new_id):
    subprocess.run(["install_name_tool", "-id", new_id, str(target)], check=False)


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: bundle-homebrew-tools.py <Tools output dir>")

    tools_dir = Path(sys.argv[1]).resolve()
    bin_dir = tools_dir / "bin"
    lib_dir = tools_dir / "lib"
    if tools_dir.exists():
        shutil.rmtree(tools_dir)
    bin_dir.mkdir(parents=True)
    lib_dir.mkdir(parents=True)

    roots = {
        "mkvmerge": which("mkvmerge"),
        "ffmpeg": which("ffmpeg"),
        "ffprobe": which("ffprobe"),
    }

    root_outputs = {}
    origins = {}
    for name, src in roots.items():
        dst = bin_dir / name
        copy_binary(src, dst)
        root_outputs[name] = dst
        origins[str(dst)] = src

    copied_libs = {}
    queue = list(root_outputs.values())
    seen_inputs = set()

    while queue:
        current = queue.pop(0)
        origin = origins.get(str(current), Path(current).resolve())
        real_origin = str(Path(origin).resolve())
        if real_origin in seen_inputs:
            continue
        seen_inputs.add(real_origin)
        for dep in otool_deps(origin):
            source = resolve_dependency(dep, loader_dir=Path(origin).parent)
            if source is None:
                continue
            basename = source.name
            destination = lib_dir / basename
            if basename not in copied_libs:
                copy_binary(source, destination)
                copied_libs[basename] = destination
                origins[str(destination)] = source
                queue.append(destination)

    for binary in root_outputs.values():
        origin = origins.get(str(binary), Path(binary).resolve())
        for dep in otool_deps(origin):
            source = resolve_dependency(dep, loader_dir=Path(origin).parent)
            if source is not None:
                basename = source.name
                if basename in copied_libs:
                    install_name_change(binary, dep, f"@loader_path/../lib/{basename}")

    for basename, lib in copied_libs.items():
        origin = origins.get(str(lib), Path(lib).resolve())
        install_name_id(lib, f"@loader_path/{basename}")
        for dep in otool_deps(origin):
            source = resolve_dependency(dep, loader_dir=Path(origin).parent)
            if source is not None:
                dep_basename = source.name
                if dep_basename in copied_libs:
                    install_name_change(lib, dep, f"@loader_path/{dep_basename}")

    print(f"已打包工具：{', '.join(root_outputs.keys())}")
    print(f"已打包动态库：{len(copied_libs)} 个")


if __name__ == "__main__":
    main()
