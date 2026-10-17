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

## 更新子模块到各自远端最新

```bash
git submodule update --remote --merge
git add . && git commit -m "chore: bump submodules"
```
