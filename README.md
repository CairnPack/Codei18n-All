# Codei18n-All

Codei18n 全家桶集合仓库，以 git submodule 形式聚合以下项目：

| 子模块 | 说明 |
| --- | --- |
| [Codei18n](https://github.com/CairnPack/Codei18n) | 代码注释国际化基础设施 |
| [Codei18n-IDEA](https://github.com/CairnPack/Codei18n-IDEA) | IntelliJ IDEA 插件 |
| [Codei18n-VSC](https://github.com/CairnPack/Codei18n-VSC) | VS Code 扩展 |
| [Codei18nDesktop](https://github.com/CairnPack/Codei18nDesktop) | 桌面图形界面 |

## 克隆

```bash
git clone --recurse-submodules https://github.com/CairnPack/Codei18n-All.git
```

已克隆但未拉取子模块时：

```bash
git submodule update --init --recursive
```

## 构建

### core 与 CLI（Codei18n）

前置条件：**Go 1.27.1+**；**MinGW-w64 gcc**，因为 core 使用 tree-sitter，需要 cgo；`CGO_ENABLED=1`。

```powershell
cd Codei18n
$env:GOTOOLCHAIN = 'go1.27.1'; $env:CGO_ENABLED = '1'
go build ./cmd/codei18n
go test -race ./...
```

翻译 API 令牌只保存在系统凭据库（Windows 凭据管理器）里，CLI、git hook 与桌面端共用。配置文件只记录令牌的引用名。

### 桌面端（Codei18nDesktop）

前置条件同上：Go 1.27.1+、MinGW-w64 gcc、`CGO_ENABLED=1`（构建脚本会自动设置）。目前只支持 Windows。

```powershell
cd Codei18nDesktop
.\scripts\build.ps1          # 产出 build/windows-amd64/Codei18n.exe 与安装包
.\scripts\build.ps1 -Test    # 先运行全部测试
```

如果要用本仓库里的 core 源码联调，执行 `go work init . ..\Codei18n`（`go.work` 不入库）。

### IDEA 插件（Codei18n-IDEA）

需要已安装的 IntelliJ IDEA（2025.1–2026.2）和 JDK 21+（可用 IDE 自带的 JBR）。

```powershell
cd Codei18n-IDEA
.\build.ps1                  # 单元测试 + build/distributions/codei18n-idea-<版本>.zip
.\test-ide.ps1               # 真实 IDE 无头集成测试（-IdeaHome 指定其他版本）
```

注意：`test-ide.ps1` 与桌面端完整构建都很占资源，不要同时运行。

## 更新子模块到各自远端最新

```bash
git submodule update --remote --merge
git add . && git commit -m "chore: bump submodules"
```
