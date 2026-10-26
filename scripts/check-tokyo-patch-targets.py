#!/usr/bin/env python3
"""도쿄 Terraform 패치가 가리키는 대상이 gitops 에 실재하는지 대조한다.

왜 있나 — 2026-10-26 하루에 같은 종류의 사고가 두 번 났다.
  ⑴ SIM-11a 주입 매니페스트가 `app: status-svc` 를 골랐는데 그 라벨의 파드가
     0개가 되어 "차단했는데 아무 일도 없었다 = Pass" 로 보였다(거짓 Pass).
  ⑵ 도쿄 평상시 대기 패치가 `Rollout/ScaledObject status-svc` 를 대상으로
     했는데 그 객체가 `web-backend` 로 이름이 바뀌었다.

🔴 둘 다 **조용히** 틀린다. Kustomize v5 는 target 이 아무것도 못 고르면
오류 없이 그 패치를 건너뛰고, Argo CD 도 경고하지 않는다(v5.8.1 실측).
도쿄는 평소에 내려가 있어 사람 눈에도 안 띈다 — 그래서 코드로 본다.

보는 것 두 가지
  A. 패치 target 의 kind/name 이 gitops manifests 에 실재하는가
  B. gitops 의 ECR 이미지가 전부 도쿄 리전 치환 목록에 들어 있는가
     (들어 있지 않으면 그 워크로드는 DR 때 서울 ECR 을 당긴다)

쓰기
  scripts/check-tokyo-patch-targets.py [gitops 경로]
  기본 경로는 이 레포 옆의 ../aquasentinel-gitops 다.
  어긋나면 1 로 끝난다.

한계 — HCL 을 정규식으로 읽는다(terraform 없이 돌리기 위해서다). 패치를
`target = { kind = "X", name = "Y" }` 꼴로 한 줄에 쓰는 지금 관례를 전제한다.
"""
import os
import re
import sys

try:
    import yaml
except ImportError:
    sys.exit("PyYAML 이 필요하다: pip install pyyaml")

HERE = os.path.dirname(os.path.abspath(__file__))
AWS_ROOT = os.path.dirname(HERE)
TOKYO_GITOPS = os.path.join(AWS_ROOT, "terraform", "tokyo", "rebuild", "3-gitops")

# Kustomize 가 읽지 않는 파일 — kustomization.yaml 이 의도적으로 제외한 수동 Job.
# 도쿄에서는 사람이 주소를 바꿔 적용한다(각 파일 머리 주석에 적혀 있다).
MANUAL_FILES = {
    "manifests/api-module/collector/collector-fishery-backfill.yaml",
    "manifests/api-module/processor/reprocess.yaml",
}


def strip_comments(text):
    return "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))


def read_tf(name, required=True):
    path = os.path.join(TOKYO_GITOPS, name)
    if not os.path.exists(path):
        if required:
            sys.exit("없는 파일: %s" % path)
        return None
    with open(path, encoding="utf-8") as f:
        return strip_comments(f.read())


def patch_targets():
    """도쿄 .tf 가 패치하는 (kind, name) 목록."""
    text = read_tf("applications.tf") + "\n" + read_tf("root.tf")
    pairs = re.findall(
        r'target\s*=\s*\{\s*kind\s*=\s*"([^"]+)"\s*,\s*name\s*=\s*"([^"]+)"', text
    )
    out = []
    for pair in pairs:
        if pair not in out:
            out.append(pair)
    return out


def override_repos():
    """ecr-images.tf 가 리전 치환하는 ECR 리포지토리 이름. 파일이 없으면 None."""
    text = read_tf("ecr-images.tf", required=False)
    if text is None:
        return None
    block = re.search(r"ecr_same_repo\s*=\s*\{(.*?)\n  \}", text, re.S)
    if not block:
        sys.exit("ecr-images.tf 에서 ecr_same_repo 를 못 찾았다 — 이 스크립트를 고쳐야 한다")
    repos = set(re.findall(r'"([a-z0-9][a-z0-9/-]*)"', block.group(1)))
    # 다이제스트 고정 이미지는 별도 항목이라 따로 더한다.
    repos |= set(re.findall(r'/\$\{local\.ecr_repo_ns\}/([a-z0-9-]+)@sha256:', text))
    return repos


def gitops_objects(root):
    """gitops 의 (kind, name) 집합과, ECR 이미지 이름 → 파일 목록.

    manifests/ 와 apps/ 둘 다 본다 — root.tf 가 패치하는 대상은 apps/ 의
    Argo CD Application 이고, applications.tf 가 패치하는 대상은 manifests/ 의
    쿠버네티스 리소스다.
    """
    objects, images = set(), {}
    img_re = re.compile(r"(\d{12})\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/([a-z0-9._/-]+)")
    walk_roots = [os.path.join(root, d) for d in ("manifests", "apps")]
    for dirpath, _, files in [t for r in walk_roots for t in os.walk(r)]:
        for fname in files:
            if not fname.endswith((".yaml", ".yml")):
                continue
            full = os.path.join(dirpath, fname)
            rel = os.path.relpath(full, root)
            with open(full, encoding="utf-8") as f:
                raw = f.read()
            for _, repo in img_re.findall(raw):
                images.setdefault(repo.split(":")[0], set()).add(rel)
            try:
                docs = list(yaml.safe_load_all(raw))
            except yaml.YAMLError:
                continue
            for doc in docs:
                if not isinstance(doc, dict) or not doc.get("kind"):
                    continue
                objects.add((doc["kind"], (doc.get("metadata") or {}).get("name")))
                for gen in doc.get("configMapGenerator") or []:
                    objects.add(("ConfigMap", gen.get("name")))
    return objects, images


def main():
    gitops = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        os.path.dirname(AWS_ROOT), "aquasentinel-gitops"
    )
    if not os.path.isdir(os.path.join(gitops, "manifests")):
        sys.exit("gitops 경로에 manifests/ 가 없다: %s" % gitops)

    objects, images = gitops_objects(gitops)
    problems = []

    targets = patch_targets()
    missing = [t for t in targets if t not in objects]
    print("A. 패치 대상 — 실재 %d / %d" % (len(targets) - len(missing), len(targets)))
    for kind, name in missing:
        problems.append(
            "패치 대상이 gitops 에 없다: %s/%s — 이름이 바뀌었는지 보라."
            " Kustomize 는 이 패치를 조용히 건너뛴다" % (kind, name)
        )

    repos = override_repos()
    if repos is None:
        print("B. ECR 이미지 — 건너뜀(ecr-images.tf 가 이 브랜치에 없다)")
        repos = set()
        skip_b = True
    else:
        skip_b = False
    ns_prefix = "aquasentinel-dev/"
    uncovered = []
    for repo, files in sorted(images.items()):
        short = repo[len(ns_prefix):] if repo.startswith(ns_prefix) else repo
        if short in repos:
            continue
        if files <= MANUAL_FILES:
            continue  # 알려진 수동 Job — 사람이 바꾼다
        uncovered.append((short, sorted(files - MANUAL_FILES)))
    if skip_b:
        uncovered = []
    else:
        print("B. ECR 이미지 — 치환됨 %d / %d" % (len(images) - len(uncovered), len(images)))
    for short, files in uncovered:
        problems.append(
            "ECR 이미지가 도쿄 치환 목록에 없다: %s (%s) —"
            " 이대로면 DR 때 서울 ECR 을 당긴다. ecr-images.tf 에 더하라"
            % (short, ", ".join(files))
        )

    if problems:
        print("\n🔴 어긋남 %d건" % len(problems))
        for p in problems:
            print("  - %s" % p)
        return 1
    print("\nOK — 어긋남 없음")
    return 0


if __name__ == "__main__":
    sys.exit(main())
