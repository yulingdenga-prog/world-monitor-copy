# World Monitor WIRE Daily Brief

自动抓取 World Monitor 的 `THE WIRE` 事件列表，并生成已经分类、润色过的中文公众号文章草稿，同时保留结构化 JSON 方便复核。

默认输出不是网页链接列表，而是按主题整理后的中文稿件，例如“中东局势与能源冲击”“俄乌战争与欧洲安全”“非洲安全与政局风险”等。

## 重要说明

World Monitor 的 `robots.txt` 对 `/api/` 路径设置了 `Disallow`。当前需求明确要求使用 WIRE 列表信息，因此配置里通过 `allowApiAccess: true` 显式开启访问。用于公开发布前，请确认你的使用方式符合目标网站条款、版权要求和内部合规要求。

## 运行

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\daily-news.ps1
```

生成文件会写入 `output/`：

- `YYYY-MM-DD_world-monitor-wire.md`：可发布的中文公众号初稿
- `YYYY-MM-DD_world-monitor-wire.json`：WIRE 原始摘要、分类、强度、提及次数等结构化数据

## 常用参数

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\daily-news.ps1 -Limit 10 -Days 3
powershell -ExecutionPolicy Bypass -File .\scripts\daily-news.ps1 -Out output
```

参数说明：

- `-Limit`：最多纳入多少条 WIRE 事件
- `-Days`：只保留最近多少天更新过的事件
- `-Out`：输出目录
- `-Config`：配置文件路径，默认 `config.json`

## 调整文章风格

编辑 `config.json` 中 `world-monitor-wire.article`：

- `titleTemplate`：公众号标题
- `intro`：开头导语
- `closing`：结语
- `categories`：分类规则
- `rewriteRules`：把 WIRE 事件匹配成中文标题和中文摘要
- `showMeta`：是否在正文中显示强度、提及次数、地点和更新时间

如果某类事件没有被规则覆盖，会使用 `fallbackTitleTemplate` 和 `fallbackSummaryTemplate` 生成中文兜底段落。想让文章更像人工编辑稿，优先补充 `rewriteRules`。

## 每日自动运行

Windows 任务计划程序可以每天定时执行：

```powershell
schtasks /Create /SC DAILY /TN "WorldMonitorWireDaily" /TR "powershell -ExecutionPolicy Bypass -File C:\Users\Administrator\Documents\Codex\2026-05-01\name-bbc-world-type-rss-url\scripts\daily-news.ps1" /ST 08:00
```

建议发布前仍做一次人工核对，尤其是战争、伤亡、恐怖主义、制裁和外交表态类内容。

## GitHub Actions 定时生成

仓库已包含 `.github/workflows/daily-world-monitor.yml`。

它会在每天北京时间 12:00 自动运行，也可以在 GitHub 页面手动触发：

1. 把本项目推送到 GitHub 仓库。
2. 打开仓库的 `Actions` 页面。
3. 选择 `Daily World Monitor Copy`。
4. 点击 `Run workflow` 可手动测试。

自动生成后，文件会出现在两个位置：

- Actions 运行记录里的 `world-monitor-copy` artifact
- 仓库中的 `copy-output/` 和 `output/` 目录

说明：本地运行时仍会输出到桌面 `文案输出` 文件夹；GitHub Actions 上没有你的桌面环境，所以使用 `copy-output/` 作为仓库内的 TXT 输出目录。

GitHub Actions 使用 UTC 时间，配置里的 `0 4 * * *` 对应北京时间中午 12:00。
