# Dota 2 地图更换器发布工作流

本文档记录每次修改、构建、GitHub Release 发布和夸克分享的标准流程。

## 1. 核心原则

1. `VERSION` 是唯一版本号来源。
2. 源码、资源和构建脚本提交到 Git；`dist` 和 `publish` 不提交。
3. GitHub Release 和夸克只使用 `publish\v版本号` 中的文件。
4. 外部 ZIP 和安装程序的文件名带版本号。
5. ZIP 内部的文件夹和 EXE 名称保持不变，避免 Steam 启动参数因升级而失效。
6. 已经公开的 Release 不覆盖同名文件；修复后增加补丁版本。

## 2. 目录和文件职责

| 路径 | 用途 | 是否提交 Git |
| --- | --- | --- |
| `VERSION` | 当前版本，例如 `1.1.5` | 是 |
| `RELEASE-NOTES.md` | 下一次 Release 的更新说明 | 是 |
| `Build-Release.ps1` | 自检并生成原始构建产物 | 是 |
| `Publish-Release.ps1` | 版本递增、发布包整理和 GitHub 发布 | 是 |
| `dist\` | 本地原始构建产物 | 否 |
| `publish\vX.Y.Z\` | 最终对外发布文件 | 否 |

每个最终发布目录应包含：

```text
publish\v1.1.6\
├─ Dota2MapSwitcher-v1.1.6-Portable.zip
├─ Dota2MapSwitcher-v1.1.6-Setup.exe
├─ 更新说明.txt
└─ SHA256SUMS.txt
```

免安装 ZIP 内部始终保持：

```text
Dota2MapSwitcher-Portable\
├─ Dota2MapSwitcher.exe
└─ 使用说明.txt
```

## 3. 版本号选择

项目使用 `major.minor.patch` 格式。

| 变更类型 | 参数 | 示例 |
| --- | --- | --- |
| Bug 修复、文案调整、小优化 | `-Bump Patch` | `1.1.5 → 1.1.6` |
| 新增向后兼容功能 | `-Bump Minor` | `1.1.6 → 1.2.0` |
| 重大不兼容改动 | `-Bump Major` | `1.2.0 → 2.0.0` |

不要因为本地重新构建、上传失败或草稿尚未发布就增加版本号。只有对外产物发生变化，或旧版已经可能被用户下载时，才发布新版本。

## 4. 日常开发流程

### 4.1 修改和检查

1. 修改源码。
2. 运行与改动风险匹配的自检。
3. 检查变更范围：

```powershell
git status --short
git diff --check
git diff
```

4. 只提交源码和文档，不要添加 `dist` 或 `publish`。

### 4.2 只做本地构建

使用 `VERSION` 中的当前版本，不改版本号：

```powershell
.\Build-Release.ps1
```

或同时生成可上传目录：

```powershell
.\Publish-Release.ps1
```

这两条命令都不会创建 Git 标签、push 或 GitHub Release。

## 5. 标准 GitHub 发布流程

### 5.1 编辑更新说明

在 `RELEASE-NOTES.md` 中只写本次变更，不需要手动写版本号和日期，脚本会在夸克用的 `更新说明.txt` 中自动补充。

建议格式：

```markdown
## 修复

- 修复……

## 新功能

- 新增……
```

### 5.2 提交功能改动

发布脚本要求工作区完全干净。在发布前先提交源码和更新说明：

```powershell
git add -- <本次修改的源码> RELEASE-NOTES.md
git commit -m "本次功能或修复的提交说明"
git status --short
```

`git status --short` 最后应没有输出。

### 5.3 检查 GitHub CLI

```powershell
gh auth status
```

如果登录无效：

```powershell
gh auth login -h github.com
gh auth status
```

### 5.4 一键发布

修复版：

```powershell
.\Publish-Release.ps1 -Bump Patch -PublishGitHub
```

功能版：

```powershell
.\Publish-Release.ps1 -Bump Minor -PublishGitHub
```

命令会依次执行：

1. 检查 Git 工作区、分支、`origin` 和 GitHub 登录。
2. 递增并写入 `VERSION`。
3. 运行自检和构建。
4. 校验 EXE 和安装程序的内部版本。
5. 生成版本化发布文件和 SHA-256。
6. 创建仅包含 `VERSION` 变更的 `发布 vX.Y.Z` 提交。
7. 创建并 push `vX.Y.Z` 标签。
8. 创建 GitHub Release 并上传 ZIP、安装程序和校验文件。

### 5.5 发布后检查

```powershell
git status --short
git log -2 --oneline
git tag --sort=-version:refname
gh release view vX.Y.Z
```

确认：

- `git status --short` 没有输出。
- 版本提交和标签指向正确。
- GitHub Release 标题和更新说明正确。
- GitHub Release 有 ZIP、Setup EXE 和 `SHA256SUMS.txt` 三个附件。
- ZIP 解压后仍为稳定的 `Dota2MapSwitcher-Portable\Dota2MapSwitcher.exe` 路径。

## 6. 夸克发布流程

GitHub 发布成功后，打开对应目录：

```text
publish\vX.Y.Z
```

将该目录中的四个文件上传到夸克，不要上传 `dist`。

建议的夸克结构：

```text
Dota 2 地图更换器\
├─ 最新版本\
│  ├─ Dota2MapSwitcher-vX.Y.Z-Portable.zip
│  ├─ Dota2MapSwitcher-vX.Y.Z-Setup.exe
│  ├─ 更新说明.txt
│  └─ SHA256SUMS.txt
└─ 历史版本\
   └─ v旧版本\
```

每次迭代：

1. 将“最新版本”中的旧文件移到“历史版本\v旧版本”。
2. 上传新版本的四个文件。
3. 检查文件名和大小。
4. 使用分享链接做一次游客视角下载测试。
5. 对外说明当前最新版本号。

不要用新二进制文件悄悄覆盖已发布的同版本。如果旧文件已有人下载，应增加 Patch 版本后重新发布。

## 7. 发布失败时如何恢复

### 7.1 在版本递增后、提交和标签之前失败

`-Bump` 会在构建前修改 `VERSION`。如果构建在此后失败，不要立即再次运行 `-Bump Patch`，否则版本号会再增加一次。

选择一种恢复方式：

- 修复构建问题后，提交当前已递增的 `VERSION`，再不带 `-Bump` 发布：

```powershell
git add -- VERSION <修复的文件>
git commit -m "修复发布构建并更新版本"
.\Publish-Release.ps1 -PublishGitHub
```

- 或者将 `VERSION` 恢复为上一版，确认问题修复后重新运行完整的 `-Bump` 命令。

### 7.2 已 push 标签，但 GitHub Release 创建失败

不要再次传 `-Bump`。确认代码、`VERSION` 和标签都正确后重试：

```powershell
.\Publish-Release.ps1 -SkipBuild -PublishGitHub
```

脚本允许已有标签指向当前提交，但会拒绝标签指向其他提交的情况。

### 7.3 GitHub Release 已经存在

脚本会停止，不会覆盖已发布附件。

- 如果现有 Release 正确，无需处理。
- 如果需要修正程序，增加 Patch 版本。
- 只有从未公开过的草稿才适合删除或替换附件。

### 7.4 GitHub CLI 登录失效

```powershell
gh auth login -h github.com
gh auth status
```

登录恢复后，根据失败发生的阶段，使用完整发布命令或 `-SkipBuild -PublishGitHub`。

## 8. 每次发布前的最终检查表

- [ ] Dota 2 地图更换逻辑已经过测试。
- [ ] `RELEASE-NOTES.md` 只包含本次更新。
- [ ] 版本类型选择正确（Patch / Minor / Major）。
- [ ] 功能改动和更新说明已提交。
- [ ] `git status --short` 没有输出。
- [ ] `gh auth status` 正常。
- [ ] 脚本构建、自检和版本校验全部通过。
- [ ] GitHub Release 附件齐全。
- [ ] 夸克“最新版本”已更新，旧版已归档。
- [ ] 分享链接已从用户视角完成下载检查。

## 9. 常用命令速查

```powershell
# 只构建当前版本
.\Build-Release.ps1

# 构建当前版本并整理 publish 目录
.\Publish-Release.ps1

# 发布下一个修复版
.\Publish-Release.ps1 -Bump Patch -PublishGitHub

# 发布下一个功能版
.\Publish-Release.ps1 -Bump Minor -PublishGitHub

# 已经构建完成，只重试 GitHub 发布
.\Publish-Release.ps1 -SkipBuild -PublishGitHub
```
